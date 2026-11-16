import Combine
import Foundation
import XCTest
import os
@testable import NewsListenApp

// facade テスト（PodcastViewModel 越しに Coordinator・Reporter・保存庫・ダウンロードを観測するテスト）共用の
// 組み立て関数と double。`PlaybackCoordinatorTests` の private な double とは別に持つ（既存テストを動かさないため）。

// MARK: - double

/// 位置の書込・完聴・取得・音声取得の呼出を、呼ばれた順に記録する。
final class EntryGatewayLog: @unchecked Sendable {
    enum Event: Equatable {
        case fetch(String)
        case updatePosition(id: String, seconds: Double)
        case markCompleted(String)
        case downloadAudio(URL)
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Event]())
    private let times = OSAllocatedUnfairLock(initialState: [Date]())
    var events: [Event] { lock.withLock { $0 } }
    /// `updatePosition` に渡された記録時刻（呼ばれた順）。`events` の `updatePosition` と同じ件数になる。
    var recordedAts: [Date] { times.withLock { $0 } }
    var fetches: [String] { events.compactMap { if case .fetch(let id) = $0 { return id } else { return nil } } }
    var updates: [(id: String, seconds: Double)] {
        events.compactMap { if case .updatePosition(let id, let seconds) = $0 { return (id, seconds) } else { return nil } }
    }
    var marks: [String] { events.compactMap { if case .markCompleted(let id) = $0 { return id } else { return nil } } }
    var downloads: [URL] { events.compactMap { if case .downloadAudio(let url) = $0 { return url } else { return nil } } }

    func record(_ event: Event) { lock.withLock { $0.append(event) } }

    func recordUpdate(id: String, seconds: Double, recordedAt: Date) {
        times.withLock { $0.append(recordedAt) }
        record(.updatePosition(id: id, seconds: seconds))
    }
}

/// 保留できる `fetchEpisode`。`hold` した id は `release` まで応答を待たせる。
final class HoldableFetch: @unchecked Sendable {
    private struct State {
        var responses: [String: Episode] = [:]
        var failures: [String: Error] = [:]
        var holds: Set<String> = []
        var parked: [String: [CheckedContinuation<Error?, Never>]] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let log: EntryGatewayLog

    init(log: EntryGatewayLog) { self.log = log }

    func respond(_ id: String, with episode: Episode) { lock.withLock { $0.responses[id] = episode } }
    func fail(_ id: String, with error: Error) { lock.withLock { $0.failures[id] = error } }
    func hold(_ id: String) { lock.withLock { _ = $0.holds.insert(id) } }

    /// 待ちに入っている呼出の数。
    func parkedCount(_ id: String) -> Int { lock.withLock { $0.parked[id]?.count ?? 0 } }

    func release(_ id: String, throwing error: Error? = nil) {
        let continuation: CheckedContinuation<Error?, Never>? = lock.withLock { state in
            guard var waiting = state.parked[id], !waiting.isEmpty else { return nil }
            let first = waiting.removeFirst()
            state.parked[id] = waiting
            return first
        }
        continuation?.resume(returning: error)
    }

    func fetch(_ id: String) async throws -> Episode {
        log.record(.fetch(id))
        let outcome: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let immediate: Bool = lock.withLock { state in
                if state.holds.contains(id) {
                    state.parked[id, default: []].append(continuation)
                    return false
                }
                return true
            }
            if immediate { continuation.resume(returning: nil) }
        }
        if let outcome { throw outcome }
        let (response, failure) = lock.withLock { ($0.responses[id], $0.failures[id]) }
        if let failure { throw failure }
        guard let response else { throw ApiFailure.unknown(status: 404) }
        return response
    }
}

/// 保留できる `downloadAudio`。
final class HoldableDownload: @unchecked Sendable {
    private struct State {
        var failure: Error?
        var data = Data([1, 2, 3])
        var holding = false
        var parked: [CheckedContinuation<Error?, Never>] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let log: EntryGatewayLog

    init(log: EntryGatewayLog) { self.log = log }

    func fail(with error: Error) { lock.withLock { $0.failure = error } }
    func hold() { lock.withLock { $0.holding = true } }
    var parkedCount: Int { lock.withLock { $0.parked.count } }

    func release(throwing error: Error? = nil) {
        let continuation: CheckedContinuation<Error?, Never>? = lock.withLock { state in
            state.parked.isEmpty ? nil : state.parked.removeFirst()
        }
        continuation?.resume(returning: error)
    }

    func download(_ url: URL) async throws -> Data {
        log.record(.downloadAudio(url))
        let outcome: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let immediate: Bool = lock.withLock { state in
                if state.holding {
                    state.parked.append(continuation)
                    return false
                }
                return true
            }
            if immediate { continuation.resume(returning: nil) }
        }
        if let outcome { throw outcome }
        let (failure, data) = lock.withLock { ($0.failure, $0.data) }
        if let failure { throw failure }
        return data
    }
}

/// Reporter の `now:` に渡す時計。
final class EntryClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 2_000_000))
    var now: Date { lock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// 接続状態を途中で変えられる `NetworkMonitoring`（`StubNetworkMonitor` は途中変更できない）。
final class MutableNetworkMonitor: NetworkMonitoring {
    private let subject: CurrentValueSubject<Bool, Never>

    init(isOnline: Bool = true) { subject = CurrentValueSubject(isOnline) }

    var isOnline: Bool {
        get { subject.value }
        set { subject.send(newValue) }
    }

    var isOnlinePublisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
}

/// 背景 task の開始・終了と、オンライン・既定速度の可変な環境。
final class EntryEnvironment: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (speed: Float(1.0), began: 0, ended: 0))
    var speed: Float {
        get { lock.withLock { $0.speed } }
        set { lock.withLock { $0.speed = newValue } }
    }
    var backgroundBegan: Int { lock.withLock { $0.began } }
    var backgroundEnded: Int { lock.withLock { $0.ended } }
    func beginBackground() -> () -> Void {
        lock.withLock { $0.began += 1 }
        return { [self] in lock.withLock { $0.ended += 1 } }
    }
}

/// 完聴後の `onCompletionRecorded` の呼出回数。
final class CompletionCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { lock.withLock { $0 } }
    func increment() { lock.withLock { $0 += 1 } }
}

/// 一覧の通信を包み、`GET /podcasts` を 1 回だけ差し替えられる `URLSessionProtocol`。
/// 差し替える一覧は「直前に受け取った一覧」へ、渡した `Podcast` を同じ id は置き換え、無い id は末尾に足した和にする。
/// それ以外の要求は包んだ session へそのまま流す。
///
/// - Important: 一覧の取得が進行中のときに `queueSeed` を呼ばない（差し替えは 1 回だけなので、重なるとどちらの要求が差し替わるか決まらない）。
final class SeedableListSession: URLSessionProtocol, @unchecked Sendable {
    private struct State {
        var list: [Podcast] = []
        var pending: Data?
    }

    private let base: URLSessionProtocol
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(base: URLSessionProtocol) { self.base = base }

    /// 次の `GET /podcasts` の応答を、直前の一覧に `podcasts` を上書き・追加した一覧にする。
    func queueSeed(_ podcasts: [Podcast]) throws {
        var merged = state.withLock { $0.list }
        for podcast in podcasts {
            if let index = merged.firstIndex(where: { $0.id == podcast.id }) {
                merged[index] = podcast
            } else {
                merged.append(podcast)
            }
        }
        let body = try EntryFixture.podcastListJSON(merged)
        state.withLock {
            $0.list = merged
            $0.pending = body
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard (request.httpMethod ?? "GET") == "GET", request.url?.path == "/podcasts" else {
            return try await base.data(for: request)
        }
        if let body = state.withLock({ state -> Data? in
            defer { state.pending = nil }
            return state.pending
        }) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        let (data, response) = try await base.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(PodcastListResponse.self, from: data) {
            state.withLock { $0.list = decoded.podcasts }
        }
        return (data, response)
    }
}

// MARK: - fixture

enum EntryFixture {
    static func content(_ id: String, duration: Int = 300) -> EpisodeContent {
        EpisodeContent(
            id: id, title: "題 \(id)", japaneseIntroText: "導入 \(id)", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: duration,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: [], sourceKind: nil
        )
    }

    static func playable(
        _ id: String, url: String? = nil, serverPosition: Double = 0, duration: Int = 300, serverRecordedAt: Date? = nil
    ) -> Episode {
        .playable(playableValue(id, url: url, serverPosition: serverPosition, duration: duration, serverRecordedAt: serverRecordedAt))
    }

    /// `playable` と同じ値を `PlayableEpisode` のまま返す（`PositionRecords.candidate(for:)` などへ渡す用）。
    static func playableValue(
        _ id: String, url: String? = nil, serverPosition: Double = 0, duration: Int = 300, serverRecordedAt: Date? = nil
    ) -> PlayableEpisode {
        PlayableEpisode(
            content: content(id, duration: duration),
            audioUrl: url ?? "https://cdn.example.com/\(id).mp3",
            serverPosition: serverPosition,
            serverRecordedAt: serverRecordedAt
        )!
    }

    /// 一覧の行（通信のデータモデル）。`serverRecordedAt` を渡すと、一覧の応答の `playback_position_recorded_at` として decode された値になる
    /// （`Podcast` の記録時刻は `private(set)` なので、JSON を経由して作る）。
    static func podcast(
        _ id: String,
        status: String = "completed",
        audioUrl: String? = nil,
        errorMessage: String? = nil,
        playbackPositionSeconds: Double = 0,
        durationSeconds: Int = 300,
        serverRecordedAt: Date? = nil
    ) -> Podcast {
        let base = Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: audioUrl ?? "https://cdn.example.com/\(id).mp3", title: "題 \(id)",
            japaneseIntroText: "導入 \(id)",
            durationSeconds: durationSeconds, createdAt: "2026-05-31T06:00:00Z", status: status,
            errorMessage: errorMessage, playbackPositionSeconds: playbackPositionSeconds, segments: nil
        )
        guard let serverRecordedAt else { return base }
        do {
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            object["playback_position_recorded_at"] = PositionSyncRules.format(serverRecordedAt)
            return try JSONDecoder().decode(Podcast.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            preconditionFailure("記録時刻つきの一覧の行を作れない: \(error)")
        }
    }

    /// 一覧の JSON（`GET /podcasts` の応答）。facade の `loadPodcasts()` に読ませる。
    static func podcastListJSON(_ podcasts: [Podcast]) throws -> Data {
        try JSONEncoder().encode(PodcastListResponse(podcasts: podcasts))
    }
}

// MARK: - 組み立て

/// facade（`PodcastViewModel`）・Coordinator・Reporter・保存庫・ダウンロード・double を 1 組で組み立てる。
@MainActor
final class PlaybackEntryRig {
    let engine = AudioEngineDouble()
    let spy: NowPlayingCenterSpy
    let library: OfflineLibrary
    let gateway = EntryGatewayLog()
    let fetch: HoldableFetch
    let download: HoldableDownload
    let network: MutableNetworkMonitor
    let clock = EntryClock()
    let environment = EntryEnvironment()
    let completions = CompletionCounter()
    let store = InMemoryPositionStore()
    let records: PositionRecords
    let reporter: PositionReporter
    let coordinator: PlaybackCoordinator
    let downloads: OfflineDownloads
    let catalog: EpisodeCatalog
    let viewModel: PodcastViewModel
    private let listSession: SeedableListSession
    private let ownsCatalog: Bool

    /// - Parameters:
    ///   - lockScreenSubtitle: ロック画面の副題の作り方（既定は難易度コードに接頭辞を付ける）。
    ///   - session: 一覧の取得に使う URLSession（既定は空 JSON を返す）。
    ///   - catalog: 外から渡す一覧（渡した rig では `seed` を使わない）。既定は `session` の通信から組む。
    ///   - onPositionSaved: 位置の保存の応答を受けたときの処理（既定は何もしない）。合成 root と同じ形の closure を渡せる。
    ///   - updatePosition: 位置の書込の応答を差し替える（既定は書込を記録して同じ位置の `Episode` を返す）。
    ///   - markCompleted: 完聴の記録を記録した後に追加で走らせる処理（実 `APIClient` へ流して要求を観測する用途）。
    ///   - onCompletion: 完聴の記録が済んだ後（`completions` を数える前）に走らせる処理。
    init(
        online: Bool = true,
        defaultSpeed: Float = 1.0,
        lockScreenSubtitle: @escaping (_ difficulty: String) -> String = { "sub:\($0)" },
        session: URLSessionProtocol? = nil,
        catalog: EpisodeCatalog? = nil,
        onPositionSaved: ((Episode) -> Void)? = nil,
        updatePosition: ((_ id: String, _ seconds: Double, _ recordedAt: Date) async throws -> Episode)? = nil,
        markCompleted: ((_ id: String) async throws -> Void)? = nil,
        onCompletion: (@MainActor () async -> Void)? = nil
    ) {
        let spy = NowPlayingCenterSpy()
        self.spy = spy
        let gateway = self.gateway
        let fetch = HoldableFetch(log: gateway)
        let download = HoldableDownload(log: gateway)
        self.fetch = fetch
        self.download = download
        let network = MutableNetworkMonitor(isOnline: online)
        self.network = network
        let environment = self.environment
        let clock = self.clock
        let completions = self.completions
        environment.speed = defaultSpeed
        let library = OfflineLibrary(
            store: .live(cacheManager: AudioCacheManager(fileManager: PodcastViewModelTests.MockFileManager())))
        library.bind(subject: subjectA)
        self.library = library
        let records = PositionRecords(store: store.store)
        records.bind(subject: subjectA)
        self.records = records

        let reporter = PositionReporter(
            updatePosition: { id, seconds, recordedAt in
                gateway.recordUpdate(id: id, seconds: seconds, recordedAt: recordedAt)
                if let updatePosition { return try await updatePosition(id, seconds, recordedAt) }
                return EntryFixture.playable(id, serverPosition: seconds)
            },
            markCompleted: { id in
                gateway.record(.markCompleted(id))
                if let markCompleted { try await markCompleted(id) }
            },
            onPositionSaved: { episode in onPositionSaved?(episode) },
            onCompletionRecorded: {
                // 呼出回数を数える前に走らせる。回数を待ったテストは、この処理も済んだ後を観測できる。
                await onCompletion?()
                completions.increment()
            },
            beginBackgroundTask: { environment.beginBackground() },
            records: records,
            connectivity: network.isOnlinePublisher,
            now: { clock.now })
        self.reporter = reporter

        let coordinator = PlaybackCoordinator(
            engine: engine,
            nowPlayingCenter: spy,
            library: library,
            reporter: reporter,
            positionRecords: records,
            fetchEpisode: { id in try await fetch.fetch(id) },
            isOnline: { network.isOnline },
            defaultSpeed: { environment.speed },
            lockScreenSubtitle: lockScreenSubtitle,
            beginBackgroundTask: { environment.beginBackground() })
        self.coordinator = coordinator

        let downloads = OfflineDownloads(
            library: library,
            fetchEpisode: { id in try await fetch.fetch(id) },
            downloadAudio: { url in try await download.download(url) },
            currentSubject: { subjectA })
        self.downloads = downloads

        let listSession = SeedableListSession(
            base: session ?? MockURLSession(data: Data(#"{"podcasts":[]}"#.utf8), statusCode: 200))
        self.listSession = listSession
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: listSession)
        ownsCatalog = catalog == nil
        let resolvedCatalog = catalog ?? EpisodeCatalog(gateway: CatalogGateway.live(apiClient: client))
        self.catalog = resolvedCatalog
        let learningGateway = LearningGateway.live(apiClient: client)
        viewModel = PodcastViewModel(
            vocabularyBook: VocabularyBook(gateway: learningGateway),
            quizGrading: QuizGrading(gateway: learningGateway),
            catalog: resolvedCatalog,
            coordinator: coordinator,
            reporter: reporter,
            positionRecords: records,
            library: library,
            downloads: downloads,
            networkMonitor: network,
            defaultSpeed: { environment.speed })
    }

    /// 保存庫に音声を置く（キャッシュ済みとして解決される）。
    func cached(_ id: String) throws {
        try library.save(Data([1, 2, 3]), for: id, subject: subjectA)
    }

    /// 取得の応答を登録する。
    func serve(_ episode: Episode) {
        if case .playable(let playable) = episode { fetch.respond(playable.content.id, with: episode) }
    }

    /// 一覧（catalog）に `podcasts` を入れる。同じ id は置き換え、無い id は末尾に足す。
    /// 一覧の取得が進行中のときに呼ばない。`catalog:` を渡した rig では使えない。
    func seed(_ podcasts: [Podcast]) async throws {
        guard ownsCatalog else {
            XCTFail("catalog を外から渡した rig では seed を使わない")
            return
        }
        try listSession.queueSeed(podcasts)
        try await catalog.reload()
    }

    /// 一覧の画面の読み込み（`loadPodcasts()`）に、次の `GET /podcasts` の応答として `podcasts` を返させて実行する。
    /// `seed(_:)` は `catalog.reload()` を直接呼ぶので `loadPodcasts()` を通らない。取り込みの入口を通すときはこちらを使う。
    /// 応答を積まずに `loadPodcasts()` を呼ぶと、`session:` に渡した base の応答（失敗など）が返る。
    func loadList(_ podcasts: [Podcast]) async throws {
        guard ownsCatalog else {
            XCTFail("catalog を外から渡した rig では loadList を使わない")
            return
        }
        try listSession.queueSeed(podcasts)
        await viewModel.loadPodcasts()
    }

    /// キャッシュ済みとして開始し、`ready`（playing）まで進める。一覧に無い id は先に入れる。
    func play(_ id: String, duration: Int = 300) async throws {
        try cached(id)
        if catalog.episode(id: id) == nil {
            try await seed([EntryFixture.podcast(id, durationSeconds: duration)])
        }
        await viewModel.startEpisode(episodeId: id)
        await engine.send(.ready)
    }
}

// MARK: - 再開位置の確認（別の端末の位置を取り込んだ状態）の fixture

extension PlaybackEntryRig {
    /// 「起きないこと」の確認の前に、保留中の Task を流す。不在には合図が無いので、同じ入口の正方向の対照と組にする。
    func settle() async {
        for _ in 0..<25 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// 条件が成り立つまで短く間隔を置いて待つ（位置の送信の完了に同期の合図が無いため）。
    func waitUntil(
        _ what: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("待ち条件が満たされなかった: \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// 別の端末が、この端末の記録より新しい時刻で書いた値を、一覧の取得として取り込む。
    /// 時刻は rig の時計より後なので、この端末の最後の記録より厳密に新しい。
    func absorbOtherDevice(_ id: String, seconds: Double, duration: Int = 300, after offset: TimeInterval = 60) {
        records.absorb([EntryFixture.playable(
            id, serverPosition: seconds, duration: duration, serverRecordedAt: clock.now.addingTimeInterval(offset))])
    }

    /// 開始 → `thisDevice` 秒まで再生 → 一時停止（Reporter がその位置を記録する）→ 別の端末の `otherDevice` 秒を取り込む。
    /// 確認の 4 条件のうち、画面のボタン以外（`paused`・取り込んだ印・差）が揃った状態にする。`otherDevice` との差は呼び出し側が決める。
    /// 一時停止は `coordinator.togglePlayPause()`（確認を出さない入口）で行う。
    func pausedWithOtherDevice(
        _ id: String = "e", thisDevice: Double = 100, otherDevice: Double = 200, duration: Int = 300
    ) async throws {
        try await play(id, duration: duration)
        await engine.send(.timeUpdate(seconds: thisDevice, duration: Double(duration)))
        coordinator.togglePlayPause()
        absorbOtherDevice(id, seconds: otherDevice, duration: duration)
    }

    /// 保存庫にある、主体 A の `id` の記録（無ければ nil）。
    func storedRecord(_ id: String) -> PositionRecord? {
        store.stored(for: subjectA).first { $0.episodeId == id }
    }
}

extension PlaybackState {
    /// 状態の種別名（付随値を無視して種別だけを比べる）。
    var stateKind: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .buffering: return "buffering"
        case .paused: return "paused"
        case .ended: return "ended"
        case .errored: return "errored"
        }
    }

    /// `loading` の再開位置（開始の直後に、どの位置から始めるかを読む）。`loading` 以外は nil。
    var loadingResumePosition: Double? {
        if case .loading(_, let resumePosition, _) = self { return resumePosition }
        return nil
    }
}

// MARK: - 字面の検査（合成 root・View の配線）

enum ResumeWiringSource {
    /// `opening`（例: `PlaybackCoordinator(`）を含む最初の非コメント行から、閉じ括弧だけの行までの非コメント行。
    static func constructionLines(in url: URL, opening: String) -> [String] {
        let lines = SourceGrep.content(of: url).components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { !SourceGrep.isCommentLine($0) && $0.contains(opening) }) else { return [] }
        var collected: [String] = []
        for line in lines[start...] {
            if !SourceGrep.isCommentLine(line) { collected.append(line) }
            if line.trimmingCharacters(in: .whitespaces) == ")" { break }
        }
        return collected
    }

    static func codeLines(in url: URL) -> [String] {
        SourceGrep.content(of: url).components(separatedBy: "\n").filter { !SourceGrep.isCommentLine($0) }
    }
}
