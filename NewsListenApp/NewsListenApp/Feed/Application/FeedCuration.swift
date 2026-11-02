//
//  FeedCuration.swift
//  NewsListenApp
//
//  フィードの一覧・楽観的な除去・取り消し猶予・確定・まとめて Star・残り回数の読み取り（application）。
//

import Foundation
import Combine

/// 通信の入口（port）。adapter が組む。
struct CurationGateway {
    let fetchFeed: () async throws -> [ArticleCardModel]
    let star: (String, DifficultyLevel?) async throws -> Void
    let dismiss: (String) async throws -> Void
    let fetchStarred: () async throws -> [ArticleCardModel]
    let unstar: (String) async throws -> Void
    let fetchAllowance: () async throws -> GenerationAllowance?
}

/// 確定の失敗。キャンセルは値にしない（黙って捨てる）。
enum CurationFailure: Error, Equatable {
    case api(ApiFailure)
    case rateLimited(GenerationLimitWait?)
    case other(String)
}

/// まとめて Star した結果の件数。
struct BulkStarReceipt: Equatable {
    let succeeded: Int
    let failed: Int
}

@MainActor
final class FeedCuration: ObservableObject {
    @Published private(set) var cards: [ArticleCardModel] = []
    @Published private(set) var pending: PendingCuration?
    @Published private(set) var lastFailure: CurationFailure?

    private let gateway: CurationGateway
    private let undoGracePeriod: Duration
    private let currentSubject: () -> SubjectKey?
    /// `pending` と同時に設定・消去する。除去した card と、積んだ時点の主体の鍵。
    private var held: (card: ArticleCardModel, subject: SubjectKey?)?
    /// 猶予中（sleep 中）の Task だけを持つ。送信中の確定は持たないので、次の操作や解放の cancel が届かない。
    private var timer: Task<Void, Never>?

    init(gateway: CurationGateway, undoGracePeriod: Duration, currentSubject: @escaping () -> SubjectKey?) {
        self.gateway = gateway
        self.undoGracePeriod = undoGracePeriod
        self.currentSubject = currentSubject
    }

    deinit {
        timer?.cancel()
    }

    func reload() async throws {
        cards = try await gateway.fetchFeed()
    }

    func generationAllowance() async throws -> GenerationAllowance? {
        do {
            return try await gateway.fetchAllowance()
        } catch ApiFailure.notFound(subject: .quota) {
            // 旧 backend にはこの API が無い。残り回数を出さないだけで失敗にはしない。
            return nil
        }
    }

    func star(articleId: String, difficulty: DifficultyLevel?) async {
        await stage(articleId: articleId, kind: .star(difficulty))
    }

    func dismiss(articleId: String) async {
        await stage(articleId: articleId, kind: .dismiss)
    }

    func undoLast() {
        guard let pending, let held else { return }
        timer?.cancel()
        timer = nil
        cards = pending.restore(held.card, into: cards)
        self.pending = nil
        self.held = nil
    }

    func commitPending() async {
        guard let pending, let held else { return }
        // 再入防止のため先に保留を解除してから送る（タイマー・画面離脱・別操作が同時に来ても 1 回）。
        self.pending = nil
        self.held = nil
        await release(pending, held: held)
    }

    func clearFailure() {
        lastFailure = nil
    }

    func bulkStar(articleIds: Set<String>) async -> BulkStarReceipt {
        // 選択中に一覧から消えた id を数えて成功数を水増ししないよう、表示中の記事に絞る。
        let ids = Array(articleIds.intersection(Set(cards.map(\.id))))
        guard !ids.isEmpty else { return BulkStarReceipt(succeeded: 0, failed: 0) }

        var succeeded = 0
        var failed = 0
        var limitRetryAfter: Int??
        let star = gateway.star

        await withTaskGroup(of: (String, Error?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await star(id, nil)
                        return (id, nil)
                    } catch {
                        return (id, error)
                    }
                }
            }
            for await (id, error) in group {
                if error == nil {
                    succeeded += 1
                    cards.removeAll { $0.id == id }
                } else {
                    failed += 1
                    if case ApiFailure.rateLimited(let retryAfter)? = error {
                        limitRetryAfter = retryAfter
                    }
                }
            }
        }

        if let retryAfter = limitRetryAfter {
            lastFailure = .rateLimited(GenerationLimitWait(retryAfterSeconds: retryAfter))
        }
        return BulkStarReceipt(succeeded: succeeded, failed: failed)
    }

    /// 楽観削除を先に反映し、前の保留はその後に確定する（連続スワイプで新しい操作が前の通信を待たない）。
    private func stage(articleId: String, kind: PendingCuration.Kind) async {
        let previous = pending
        let previousHeld = held
        // 旧タイマーを残すと、後から積んだ保留の猶予が縮む。
        timer?.cancel()
        timer = nil
        let subject = currentSubject()
        if let index = cards.firstIndex(where: { $0.id == articleId }) {
            let card = cards.remove(at: index)
            held = (card, subject)
            pending = PendingCuration(kind: kind, articleId: articleId, originalIndex: index)
            scheduleTimer()
        } else {
            held = nil
            pending = nil
        }
        if let previous, let previousHeld {
            await release(previous, held: previousHeld)
        }
    }

    /// タイマー自身が `commitPending()` を呼ぶので、`commitPending()` は自分のタイマーを cancel しない。
    private func scheduleTimer() {
        timer = Task { [weak self, undoGracePeriod] in
            try? await Task.sleep(for: undoGracePeriod)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // 送信前に参照を外す。残すと次の操作の cancel が送信中の確定に届く。
            self.timer = nil
            await self.commitPending()
        }
    }

    /// 保留を積んだ主体が去っていれば、送らず記事も戻さずに捨てる。
    private func release(_ pending: PendingCuration, held: (card: ArticleCardModel, subject: SubjectKey?)) async {
        guard held.subject == currentSubject() else { return }
        await commit(pending, card: held.card)
    }

    private func commit(_ pending: PendingCuration, card: ArticleCardModel) async {
        do {
            switch pending.kind {
            case .star(let difficulty):
                try await gateway.star(pending.articleId, difficulty)
            case .dismiss:
                try await gateway.dismiss(pending.articleId)
            }
        } catch ApiFailure.rateLimited(let retryAfter) {
            cards = pending.restore(card, into: cards)
            lastFailure = .rateLimited(GenerationLimitWait(retryAfterSeconds: retryAfter))
        } catch is CancellationError {
            // 呼び出し元がキャンセルされただけ。記事は戻さない（backend が除外済みで、次の再読込で収束する）。
            return
        } catch let error as URLError where error.code == .cancelled {
            // 実 URLSession はキャンセルを URLError で投げる。同上。
            return
        } catch let failure as ApiFailure {
            cards = pending.restore(card, into: cards)
            lastFailure = .api(failure)
        } catch {
            cards = pending.restore(card, into: cards)
            lastFailure = .other(error.localizedDescription)
        }
    }
}
