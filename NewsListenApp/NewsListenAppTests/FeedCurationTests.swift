import Combine
import XCTest
@testable import NewsListenApp

/// 確定待ち・取り消し・一括 Star・確定の失敗を持つ `FeedCuration`（application）と、その gateway adapter
/// （`CurationGateway.live`・変換）のテスト。closure の gateway で呼出を記録する。
@MainActor
final class FeedCurationTests: XCTestCase {

    // MARK: - 補助

    private func card(_ id: String) -> ArticleCardModel {
        ArticleCardModel(id: id, title: "T-\(id)", url: "https://example.com/\(id)", source: "s", score: 0.5, publishedAt: "2026-05-31T06:00:00Z")
    }

    private func ids(_ cards: [ArticleCardModel]) -> [String] { cards.map(\.id) }

    /// 現在の主体の鍵を差し替えられる箱。
    private final class SubjectBox {
        var key: SubjectKey?
        init(_ key: SubjectKey?) { self.key = key }
    }

    /// 呼出を記録する gateway。star・dismiss の振る舞いは差し替えられる。
    private final class FakeGateway {
        var feed: [ArticleCardModel] = []
        private(set) var starCalls: [(id: String, difficulty: DifficultyLevel?)] = []
        private(set) var dismissCalls: [String] = []
        private(set) var unstarCalls: [String] = []
        private(set) var feedCalls = 0
        private(set) var starredCalls = 0
        var starBehavior: (String) async throws -> Void = { _ in }
        var dismissBehavior: (String) async throws -> Void = { _ in }
        var feedBehavior: (() async throws -> Void)?
        var allowanceBehavior: () async throws -> GenerationAllowance? = { nil }
        /// star の呼出時点の `cards` の id を記録する。
        var cardsProbe: (() -> [String])?
        private(set) var cardsAtStar: [[String]] = []

        var starIds: [String] { starCalls.map(\.id) }

        var gateway: CurationGateway {
            CurationGateway(
                fetchFeed: { @MainActor in
                    self.feedCalls += 1
                    try await self.feedBehavior?()
                    return self.feed
                },
                star: { @MainActor id, difficulty in
                    self.starCalls.append((id, difficulty))
                    if let probe = self.cardsProbe { self.cardsAtStar.append(probe()) }
                    try await self.starBehavior(id)
                },
                dismiss: { @MainActor id in
                    self.dismissCalls.append(id)
                    try await self.dismissBehavior(id)
                },
                fetchStarred: { @MainActor in
                    self.starredCalls += 1
                    return self.feed
                },
                unstar: { @MainActor id in
                    self.unstarCalls.append(id)
                },
                fetchAllowance: { @MainActor in
                    try await self.allowanceBehavior()
                }
            )
        }
    }

    private func makeCuration(
        _ fake: FakeGateway,
        grace: Duration = .seconds(60),
        subject: SubjectBox = SubjectBox(nil),
        cards: [String] = []
    ) async throws -> FeedCuration {
        let curation = FeedCuration(gateway: fake.gateway, undoGracePeriod: grace, currentSubject: { subject.key })
        if !cards.isEmpty {
            fake.feed = cards.map(card)
            try await curation.reload()
        }
        return curation
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(10),
        condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - 生成（ios-test-008）

    // verifies: ios-cmd-curation-01
    func testInitStartsEmptyAndDoesNotCallGateway() {
        let fake = FakeGateway()
        let curation = FeedCuration(gateway: fake.gateway, undoGracePeriod: .seconds(4), currentSubject: { nil })

        XCTAssertTrue(curation.cards.isEmpty)
        XCTAssertNil(curation.pending)
        XCTAssertNil(curation.lastFailure)
        XCTAssertEqual(fake.starCalls.count + fake.dismissCalls.count + fake.feedCalls + fake.starredCalls + fake.unstarCalls.count, 0)
    }

    // MARK: - stage（ios-test-008）

    // verifies: ios-cmd-curation-01
    func testStarRemovesCardAndHoldsPendingWithoutCommunication() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        await curation.star(articleId: "a1", difficulty: nil)

        XCTAssertEqual(ids(curation.cards), ["a2"])
        XCTAssertEqual(curation.pending, PendingCuration(kind: .star(nil), articleId: "a1", originalIndex: 0))
        XCTAssertTrue(fake.starCalls.isEmpty)
        XCTAssertTrue(fake.dismissCalls.isEmpty)
    }

    // verifies: ios-cmd-curation-01
    func testStarWithDifficultyKeepsDifficultyInPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        await curation.star(articleId: "a2", difficulty: .toeic600)

        XCTAssertEqual(curation.pending, PendingCuration(kind: .star(.toeic600), articleId: "a2", originalIndex: 1))
    }

    // verifies: ios-cmd-curation-01
    func testDismissRemovesCardAndHoldsDismissPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        await curation.dismiss(articleId: "a2")

        XCTAssertEqual(ids(curation.cards), ["a1"])
        XCTAssertEqual(curation.pending, PendingCuration(kind: .dismiss, articleId: "a2", originalIndex: 1))
        XCTAssertTrue(fake.dismissCalls.isEmpty)
    }

    // verifies: ios-cmd-curation-01
    func testStagingNewActionCommitsPreviousAfterRemovingNewCard() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        fake.cardsProbe = { curation.cards.map(\.id) }

        await curation.star(articleId: "a1", difficulty: nil)
        await curation.dismiss(articleId: "a2")

        XCTAssertEqual(fake.starIds, ["a1"])
        // 前の確定を送る時点で、新しい記事は既に一覧から除かれている（前の通信を待たない）。
        XCTAssertEqual(fake.cardsAtStar, [[]])
        XCTAssertEqual(curation.pending?.articleId, "a2")
        XCTAssertEqual(curation.pending?.kind, .dismiss)
        XCTAssertTrue(curation.cards.isEmpty)
    }

    // verifies: ios-cmd-curation-01
    func testStagingUnknownArticleCommitsPreviousWithoutNewPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        await curation.star(articleId: "a1", difficulty: nil)
        await curation.star(articleId: "ghost", difficulty: nil)

        XCTAssertNil(curation.pending)
        XCTAssertEqual(fake.starIds, ["a1"])
        XCTAssertEqual(ids(curation.cards), ["a2"])
    }

    // verifies: ios-cmd-curation-01
    func testStagingUnknownArticleWithoutPendingDoesNothing() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1"])

        await curation.dismiss(articleId: "ghost")

        XCTAssertNil(curation.pending)
        XCTAssertEqual(ids(curation.cards), ["a1"])
        XCTAssertTrue(fake.starCalls.isEmpty && fake.dismissCalls.isEmpty)
    }

    // MARK: - undoLast（ios-test-105）

    // verifies: ios-cmd-curation-02
    func testUndoLastRestoresCardAtOriginalIndexWithoutCommunication() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, grace: .milliseconds(50), cards: ["a1", "a2", "a3"])

        await curation.dismiss(articleId: "a2")
        curation.undoLast()

        XCTAssertEqual(ids(curation.cards), ["a1", "a2", "a3"])
        XCTAssertNil(curation.pending)
        XCTAssertTrue(fake.dismissCalls.isEmpty)
        // 取り消したタイマーは動かない（猶予の 20 倍待っても呼出 0）。
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(fake.dismissCalls.isEmpty)
        XCTAssertEqual(ids(curation.cards), ["a1", "a2", "a3"])
    }

    // verifies: ios-cmd-curation-02
    func testUndoLastWithoutPendingIsNoOp() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1"])

        curation.undoLast()

        XCTAssertEqual(ids(curation.cards), ["a1"])
        XCTAssertNil(curation.pending)
    }

    // MARK: - commitPending（ios-test-105）

    // verifies: ios-cmd-curation-02
    func testCommitPendingSendsOnceEvenWhenCalledConcurrently() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { _ in try await Task.sleep(for: .milliseconds(30)) }   // 再入を狙える suspension
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        await curation.star(articleId: "a1", difficulty: nil)

        async let first: Void = curation.commitPending()
        async let second: Void = curation.commitPending()
        _ = await (first, second)
        await curation.commitPending()

        XCTAssertEqual(fake.starIds, ["a1"])
        XCTAssertNil(curation.pending)
        XCTAssertEqual(ids(curation.cards), ["a2"])
        XCTAssertNil(curation.lastFailure)
    }

    // verifies: ios-cmd-curation-02
    func testCommitPendingWithoutPendingIsNoOp() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1"])

        await curation.commitPending()

        XCTAssertTrue(fake.starCalls.isEmpty && fake.dismissCalls.isEmpty)
        XCTAssertNil(curation.lastFailure)
    }

    // verifies: ios-cmd-curation-02
    func testCommitPendingSendsDismissForDismissPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        await curation.dismiss(articleId: "a1")
        await curation.commitPending()

        XCTAssertEqual(fake.dismissCalls, ["a1"])
        XCTAssertTrue(fake.starCalls.isEmpty)
    }

    // MARK: - 確定の失敗（ios-test-105・ios-dec-98）

    private func failureOutcome(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (cards: [String], failure: CurationFailure?) {
        let fake = FakeGateway()
        fake.starBehavior = { _ in throw error }
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        await curation.star(articleId: "a1", difficulty: nil)
        await curation.commitPending()
        XCTAssertNil(curation.pending, file: file, line: line)
        return (ids(curation.cards), curation.lastFailure)
    }

    // verifies: ios-dec-98
    func testCommitFailureWithApiFailureRestoresCardAndSetsApiFailure() async throws {
        let outcome = try await failureOutcome(ApiFailure.server(status: 500))

        XCTAssertEqual(outcome.cards, ["a1", "a2"])
        XCTAssertEqual(outcome.failure, .api(.server(status: 500)))
    }

    // verifies: ios-dec-98
    func testCommitFailureWithOtherErrorRestoresCardAndKeepsLocalizedDescription() async throws {
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "壊れた"])
        let outcome = try await failureOutcome(error)

        XCTAssertEqual(outcome.cards, ["a1", "a2"])
        XCTAssertEqual(outcome.failure, .other(error.localizedDescription))
    }

    // verifies: ios-dec-98
    func testCommitFailureWithRateLimitedMapsRetryAfterToWait() async throws {
        let hours = try await failureOutcome(ApiFailure.rateLimited(retryAfter: 43200))
        XCTAssertEqual(hours.cards, ["a1", "a2"])
        XCTAssertEqual(hours.failure, .rateLimited(.hours(12)))

        let none = try await failureOutcome(ApiFailure.rateLimited(retryAfter: nil))
        XCTAssertEqual(none.cards, ["a1", "a2"])
        XCTAssertEqual(none.failure, .rateLimited(nil))

        let zero = try await failureOutcome(ApiFailure.rateLimited(retryAfter: 0))
        XCTAssertEqual(zero.failure, .rateLimited(nil))
    }

    // verifies: ios-dec-98
    func testCommitCancellationNeitherRestoresCardNorSetsFailure() async throws {
        let raw = try await failureOutcome(CancellationError())
        XCTAssertEqual(raw.cards, ["a2"])
        XCTAssertNil(raw.failure)

        let url = try await failureOutcome(URLError(.cancelled))
        XCTAssertEqual(url.cards, ["a2"])
        XCTAssertNil(url.failure)
    }

    // verifies: ios-dec-98
    func testNonCancelledURLErrorIsTreatedAsOtherFailure() async throws {
        let error = URLError(.notConnectedToInternet)
        let outcome = try await failureOutcome(error)

        XCTAssertEqual(outcome.cards, ["a1", "a2"])
        XCTAssertEqual(outcome.failure, .other(error.localizedDescription))
    }

    // verifies: ios-dec-98
    func testCommitSuccessKeepsExistingFailure() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { id in if id == "a1" { throw ApiFailure.server(status: 500) } }
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        await curation.star(articleId: "a1", difficulty: nil)
        await curation.commitPending()
        XCTAssertEqual(curation.lastFailure, .api(.server(status: 500)))

        await curation.star(articleId: "a2", difficulty: nil)
        await curation.commitPending()

        XCTAssertEqual(curation.lastFailure, .api(.server(status: 500)), "成功は lastFailure を変えない")
    }

    // verifies: ios-dec-98
    func testStagingFailureOfPreviousCommitRestoresIntoCurrentCards() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { _ in throw ApiFailure.server(status: 500) }
        let curation = try await makeCuration(fake, cards: ["a1", "a2", "a3"])

        await curation.star(articleId: "a2", difficulty: nil)       // index 1
        await curation.dismiss(articleId: "a3")                     // a2 の確定が失敗 → 現在の cards に戻る

        XCTAssertEqual(ids(curation.cards), ["a1", "a2"])
        XCTAssertEqual(curation.lastFailure, .api(.server(status: 500)))
        XCTAssertEqual(curation.pending?.articleId, "a3")
    }

    // verifies: ios-cmd-curation-02
    func testClearFailureResetsLastFailure() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { _ in throw ApiFailure.server(status: 500) }
        let curation = try await makeCuration(fake, cards: ["a1"])
        await curation.star(articleId: "a1", difficulty: nil)
        await curation.commitPending()
        XCTAssertNotNil(curation.lastFailure)

        curation.clearFailure()

        XCTAssertNil(curation.lastFailure)
    }

    // MARK: - 自動確定（ios-test-105）

    // verifies: ios-cmd-curation-02
    func testGracePeriodElapsingCommitsPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, grace: .milliseconds(50), cards: ["a1"])

        await curation.star(articleId: "a1", difficulty: nil)
        XCTAssertTrue(fake.starCalls.isEmpty, "猶予中は送信しない")

        await waitUntil { fake.starCalls.count == 1 }

        XCTAssertEqual(fake.starIds, ["a1"])
        XCTAssertNil(curation.pending)
    }

    // verifies: ios-cmd-curation-02
    func testAutoCommitFailureIsReportedThroughLastFailure() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { _ in throw ApiFailure.server(status: 500) }
        let curation = try await makeCuration(fake, grace: .milliseconds(50), cards: ["a1", "a2"])

        await curation.star(articleId: "a1", difficulty: nil)
        await waitUntil { curation.lastFailure != nil }

        XCTAssertEqual(curation.lastFailure, .api(.server(status: 500)))
        XCTAssertEqual(ids(curation.cards), ["a1", "a2"])
    }

    // verifies: ios-cmd-curation-02
    func testStagingNewActionRestartsFullGracePeriod() async throws {
        // 猶予 800ms・A→B の間隔 300ms。再起動しない実装なら B は B の stage から 500ms 後に確定し、
        // 650ms の時点で送信済みになる。再起動する実装なら 800ms 後なので 650ms の時点では未送信。
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, grace: .milliseconds(800), cards: ["a1", "a2"])

        await curation.star(articleId: "a1", difficulty: nil)
        try await Task.sleep(for: .milliseconds(300))
        await curation.dismiss(articleId: "a2")
        XCTAssertEqual(fake.starIds, ["a1"])

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(fake.dismissCalls.isEmpty, "B の猶予が縮んでいない")
        XCTAssertNotNil(curation.pending)

        await waitUntil(timeout: .seconds(2)) { fake.dismissCalls == ["a2"] }
        XCTAssertEqual(fake.dismissCalls, ["a2"])
        XCTAssertNil(curation.pending)
    }

    // verifies: ios-cmd-curation-02
    func testReleasedCurationNeverCommitsAfterTimerWouldFire() async throws {
        let fake = FakeGateway()
        weak var weakCuration: FeedCuration?
        do {
            let curation = try await makeCuration(fake, grace: .milliseconds(50), cards: ["a1"])
            weakCuration = curation
            await curation.star(articleId: "a1", difficulty: nil)
        }

        XCTAssertNil(weakCuration, "タイマーが self を強く保持していない")
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(fake.starCalls.isEmpty, "解放後に通信しない")
    }

    // MARK: - 通信中の確定を cancel しない（ios-test-105）

    /// 通信中の star を手動で再開するまで保留し、cancel を受けたかを記録する。
    private final class InFlightGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        var isWaiting: Bool { lock.withLock { continuation != nil } }

        func hold() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.withLock { continuation = c }
                }
            } onCancel: {
                lock.withLock { cancelled = true }
            }
        }

        func resume() {
            let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    // verifies: ios-cmd-curation-02
    func testNextStageDoesNotCancelAutoCommitInFlight() async throws {
        let gate = InFlightGate()
        let fake = FakeGateway()
        fake.starBehavior = { id in if id == "a1" { await gate.hold() } }
        let curation = try await makeCuration(fake, grace: .milliseconds(50), cards: ["a1", "a2"])

        await curation.star(articleId: "a1", difficulty: nil)
        await waitUntil { gate.isWaiting }                  // 自動確定の通信中
        XCTAssertTrue(gate.isWaiting)
        await curation.dismiss(articleId: "a2")
        gate.resume()
        await waitUntil { fake.dismissCalls == ["a2"] }

        XCTAssertFalse(gate.isCancelled, "次の操作が通信中の確定を打ち切らない")
        XCTAssertNil(curation.lastFailure)
        XCTAssertEqual(curation.cards.map(\.id), [], "a1 は戻らない")
        XCTAssertEqual(fake.dismissCalls, ["a2"])
        XCTAssertEqual(fake.starIds, ["a1"])
    }

    // verifies: ios-cmd-curation-02
    func testUndoLastDuringAutoCommitInFlightDoesNotCancelIt() async throws {
        let gate = InFlightGate()
        let fake = FakeGateway()
        fake.starBehavior = { _ in await gate.hold() }
        let curation = try await makeCuration(fake, grace: .milliseconds(50), cards: ["a1", "a2"])

        await curation.star(articleId: "a1", difficulty: nil)
        await waitUntil { gate.isWaiting }
        XCTAssertTrue(gate.isWaiting)
        curation.undoLast()
        gate.resume()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(gate.isCancelled)
        XCTAssertNil(curation.lastFailure)
        XCTAssertEqual(curation.cards.map(\.id), ["a2"], "送信済みの a1 は戻らない")
        XCTAssertNil(curation.pending)
    }

    // MARK: - 主体の交代（ios-test-105・ios-dec-99・ios-dec-101）

    private func assertDropsPending(
        newKey: SubjectKey?,
        file: StaticString = #filePath,
        line: UInt = #line,
        trigger: (FeedCuration) async -> Void
    ) async throws {
        let fake = FakeGateway()
        let subject = SubjectBox(subjectA)
        let curation = try await makeCuration(fake, grace: .milliseconds(80), subject: subject, cards: ["a1", "a2", "a3"])
        await curation.star(articleId: "a1", difficulty: nil)
        subject.key = newKey

        await trigger(curation)
        try await Task.sleep(for: .milliseconds(250))   // タイマーが動く場合の余白

        XCTAssertTrue(fake.starCalls.isEmpty, "A の保留を送らない", file: file, line: line)
        XCTAssertFalse(curation.cards.contains { $0.id == "a1" }, "記事を戻さない", file: file, line: line)
        XCTAssertNil(curation.lastFailure, file: file, line: line)
    }

    // verifies: ios-dec-101
    func testCommitPendingDropsPendingWhenSubjectLoggedOut() async throws {
        try await assertDropsPending(newKey: nil) { curation in
            await curation.commitPending()
            XCTAssertNil(curation.pending)
        }
    }

    // verifies: ios-dec-99
    func testCommitPendingDropsPendingWhenSubjectSwitchedDirectly() async throws {
        try await assertDropsPending(newKey: subjectB) { curation in
            await curation.commitPending()
            XCTAssertNil(curation.pending)
        }
    }

    // verifies: ios-dec-101
    func testTimerDropsPendingWhenSubjectChanged() async throws {
        for newKey in [nil, subjectB] {
            try await assertDropsPending(newKey: newKey) { curation in
                await self.waitUntil { curation.pending == nil }
                XCTAssertNil(curation.pending)
            }
        }
    }

    // verifies: ios-dec-99
    func testStagingAnotherActionDropsPendingOfDepartedSubject() async throws {
        for newKey in [nil, subjectB] {
            let fake = FakeGateway()
            let subject = SubjectBox(subjectA)
            let curation = try await makeCuration(fake, subject: subject, cards: ["a1", "a2", "a3"])
            await curation.star(articleId: "a1", difficulty: nil)
            subject.key = newKey

            await curation.dismiss(articleId: "a2")

            XCTAssertTrue(fake.starCalls.isEmpty)
            XCTAssertEqual(curation.cards.map(\.id), ["a3"], "a1 は戻らず a2 は除かれる")
            XCTAssertNil(curation.lastFailure)
            XCTAssertEqual(curation.pending?.articleId, "a2")

            // 新しい保留は新しい主体の鍵で積まれるので、そのまま確定できる。
            await curation.commitPending()
            XCTAssertEqual(fake.dismissCalls, ["a2"])
        }
    }

    // verifies: ios-dec-99
    func testPendingIsSentWhenSubjectKeyStaysNil() async throws {
        let fake = FakeGateway()
        let subject = SubjectBox(nil)
        let curation = try await makeCuration(fake, subject: subject, cards: ["a1"])
        await curation.star(articleId: "a1", difficulty: nil)

        await curation.commitPending()

        XCTAssertEqual(fake.starIds, ["a1"])
    }

    // verifies: ios-dec-99
    func testPendingIsSentWhenSubjectKeyStaysTheSame() async throws {
        let fake = FakeGateway()
        let subject = SubjectBox(subjectA)
        let curation = try await makeCuration(fake, subject: subject, cards: ["a1"])
        await curation.star(articleId: "a1", difficulty: nil)
        subject.key = SubjectKey("user-a")

        await curation.commitPending()

        XCTAssertEqual(fake.starIds, ["a1"])
    }

    // MARK: - bulkStar（ios-test-009）

    // verifies: ios-cmd-curation-03
    func testBulkStarCountsOnlyDisplayedArticlesAndRemovesSucceeded() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        let receipt: BulkStarReceipt = await curation.bulkStar(articleIds: ["a1", "a2", "ghost"])

        XCTAssertEqual(receipt, BulkStarReceipt(succeeded: 2, failed: 0))
        XCTAssertTrue(curation.cards.isEmpty)
        XCTAssertEqual(fake.starIds.sorted(), ["a1", "a2"])
        XCTAssertTrue(fake.starCalls.allSatisfy { $0.difficulty == nil }, "難易度なし")
    }

    // verifies: ios-cmd-curation-03
    func testBulkStarPartialFailureCountsOnlyAndKeepsFailedCard() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { id in if id == "a2" { throw ApiFailure.server(status: 500) } }
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])

        let receipt: BulkStarReceipt = await curation.bulkStar(articleIds: ["a1", "a2"])

        XCTAssertEqual(receipt, BulkStarReceipt(succeeded: 1, failed: 1))
        XCTAssertEqual(ids(curation.cards), ["a2"])
        XCTAssertNil(curation.lastFailure, "上限以外の失敗は件数だけ")
    }

    // verifies: ios-cmd-curation-03
    func testBulkStarRateLimitedSetsLastFailureExactlyOnce() async throws {
        let fake = FakeGateway()
        fake.starBehavior = { _ in throw ApiFailure.rateLimited(retryAfter: 43200) }
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        var emissions = 0
        let cancellable = curation.$lastFailure.sink { if $0 != nil { emissions += 1 } }

        let receipt: BulkStarReceipt = await curation.bulkStar(articleIds: ["a1", "a2"])

        XCTAssertEqual(receipt, BulkStarReceipt(succeeded: 0, failed: 2))
        XCTAssertEqual(curation.lastFailure, .rateLimited(.hours(12)))
        XCTAssertEqual(emissions, 1, "上限の失敗は 1 回だけ立てる")
        XCTAssertEqual(ids(curation.cards), ["a1", "a2"])
        cancellable.cancel()
    }

    // verifies: ios-cmd-curation-03
    func testBulkStarWithNoOverlapReturnsZeroWithoutCommunication() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1"])

        let receipt: BulkStarReceipt = await curation.bulkStar(articleIds: ["x", "y"])
        let empty: BulkStarReceipt = await curation.bulkStar(articleIds: [])

        XCTAssertEqual(receipt, BulkStarReceipt(succeeded: 0, failed: 0))
        XCTAssertEqual(empty, BulkStarReceipt(succeeded: 0, failed: 0))
        XCTAssertTrue(fake.starCalls.isEmpty)
    }

    // verifies: ios-cmd-curation-03
    func testBulkStarDoesNotTouchPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2", "a3"])
        await curation.dismiss(articleId: "a3")

        _ = await curation.bulkStar(articleIds: ["a1", "a2"])

        XCTAssertEqual(curation.pending, PendingCuration(kind: .dismiss, articleId: "a3", originalIndex: 2))
        XCTAssertTrue(fake.dismissCalls.isEmpty)
    }

    // MARK: - reload・generationAllowance

    // verifies: ios-query-curation-01
    func testReloadReplacesCardsWithoutTouchingPending() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        await curation.star(articleId: "a1", difficulty: nil)
        fake.feed = ["a2", "a3"].map(card)

        try await curation.reload()

        XCTAssertEqual(ids(curation.cards), ["a2", "a3"])
        XCTAssertEqual(curation.pending?.articleId, "a1")
        XCTAssertTrue(fake.starCalls.isEmpty, "再読込は確定しない")
    }

    // verifies: ios-query-curation-01
    func testReloadFailureThrowsAndKeepsCards() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake, cards: ["a1", "a2"])
        fake.feedBehavior = { throw ApiFailure.server(status: 500) }

        do {
            try await curation.reload()
            XCTFail("失敗は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
        XCTAssertEqual(ids(curation.cards), ["a1", "a2"])
    }

    // verifies: ios-query-curation-03
    func testGenerationAllowanceMapsQuotaNotFoundToNilAndRethrowsOthers() async throws {
        let fake = FakeGateway()
        let curation = try await makeCuration(fake)

        fake.allowanceBehavior = { GenerationAllowance(limit: 5, used: 2, remaining: 3) }
        let value = try await curation.generationAllowance()
        XCTAssertEqual(value?.remaining, 3)

        fake.allowanceBehavior = { throw ApiFailure.notFound(subject: .quota) }
        let missing = try await curation.generationAllowance()
        XCTAssertNil(missing)

        fake.allowanceBehavior = { throw ApiFailure.notFound(subject: .star) }
        do {
            _ = try await curation.generationAllowance()
            XCTFail("quota 以外の 404 は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .notFound(subject: .star))
        }

        fake.allowanceBehavior = { throw ApiFailure.server(status: 500) }
        do {
            _ = try await curation.generationAllowance()
            XCTFail("失敗は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    // MARK: - CurationGateway.live（adapter。ios-test-041・ios-dec-99）

    private let feedJSON = #"{"articles":[{"id":"a1","title":"Rust","url":"https://example.com/a1","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"},{"id":"a2","title":"Go","url":"https://example.com/a2","source":"zenn","score":0.7,"published_at":"2026-05-31T05:00:00Z"}],"date":"2026-05-31"}"#

    private func client(session: URLSessionProtocol) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
    }

    // verifies: ios-rule-curation-05
    func testLiveStarSendsDifficultyCodeInRequestBody() async throws {
        let session = MockURLSession(data: Data(feedJSON.utf8), statusCode: 200)
        let apiClient = client(session: session)
        let curation = FeedCuration(gateway: .live(client: { apiClient }), undoGracePeriod: .seconds(60), currentSubject: { nil })
        try await curation.reload()

        await curation.star(articleId: "a1", difficulty: .ielts7)
        await curation.commitPending()

        XCTAssertEqual(session.lastRequest?.url?.path, "/articles/a1/star")
        let body = try XCTUnwrap(session.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["difficulty"], "ielts_7")
    }

    // verifies: ios-rule-curation-05
    func testLiveStarWithoutDifficultySendsNoBody() async throws {
        let session = MockURLSession(data: Data(feedJSON.utf8), statusCode: 200)
        let apiClient = client(session: session)
        let curation = FeedCuration(gateway: .live(client: { apiClient }), undoGracePeriod: .seconds(60), currentSubject: { nil })
        try await curation.reload()

        await curation.star(articleId: "a1", difficulty: nil)
        await curation.commitPending()

        XCTAssertEqual(session.lastRequest?.url?.path, "/articles/a1/star")
        XCTAssertNil(session.lastRequest?.httpBody)
    }

    // verifies: ios-dec-99
    func testLiveWithoutClientDoesNothingAndReturnsEmptyValues() async throws {
        let gateway = CurationGateway.live(client: { nil })

        let feed = try await gateway.fetchFeed()
        let starred = try await gateway.fetchStarred()
        let allowance = try await gateway.fetchAllowance()
        try await gateway.star("a1", .toeic600)
        try await gateway.dismiss("a1")
        try await gateway.unstar("a1")

        XCTAssertEqual(feed, [])
        XCTAssertEqual(starred, [])
        XCTAssertNil(allowance)
    }

    // verifies: ios-dec-99
    func testLiveEvaluatesClientOnEveryCall() async throws {
        let first = MockURLSession(data: Data(feedJSON.utf8), statusCode: 200)
        let second = MockURLSession(data: Data(feedJSON.utf8), statusCode: 200)
        var current = client(session: first)
        let gateway = CurationGateway.live(client: { current })

        _ = try await gateway.fetchFeed()
        XCTAssertNotNil(first.lastRequest)
        XCTAssertNil(second.lastRequest)

        current = client(session: second)
        _ = try await gateway.fetchFeed()

        XCTAssertNotNil(second.lastRequest, "2 回目の呼出は差し替えた client へ届く")
    }

    // verifies: ios-dec-99
    func testLiveFetchFeedMapsAllSixFieldsAndDropsDate() async throws {
        let apiClient = client(session: MockURLSession(data: Data(feedJSON.utf8), statusCode: 200))
        let gateway = CurationGateway.live(client: { apiClient })

        let cards = try await gateway.fetchFeed()

        XCTAssertEqual(cards, [
            ArticleCardModel(id: "a1", title: "Rust", url: "https://example.com/a1", source: "hackernews", score: 0.9, publishedAt: "2026-05-31T06:00:00Z"),
            ArticleCardModel(id: "a2", title: "Go", url: "https://example.com/a2", source: "zenn", score: 0.7, publishedAt: "2026-05-31T05:00:00Z"),
        ])
    }

    // verifies: ios-dec-99
    func testLiveFetchStarredMapsArticles() async throws {
        let json = #"{"articles":[{"id":"s1","title":"Swift","url":"https://example.com/s1","source":"zenn","score":0.1,"published_at":"2026-05-30T00:00:00Z"}]}"#
        let apiClient = client(session: MockURLSession(data: Data(json.utf8), statusCode: 200))
        let gateway = CurationGateway.live(client: { apiClient })

        let cards = try await gateway.fetchStarred()

        XCTAssertEqual(cards, [ArticleCardModel(id: "s1", title: "Swift", url: "https://example.com/s1", source: "zenn", score: 0.1, publishedAt: "2026-05-30T00:00:00Z")])
    }

    // verifies: ios-query-curation-03
    func testLiveFetchAllowanceMapsNegativeLimitToNilAndZeroToUnlimited() async throws {
        let negative = client(session: MockURLSession(data: Data(#"{"limit":-1,"used":0,"remaining":null,"reset_at":"2026-07-07T00:00:00Z"}"#.utf8), statusCode: 200))
        let unlimited = client(session: MockURLSession(data: Data(#"{"limit":0,"used":0,"remaining":null,"reset_at":"2026-07-07T00:00:00Z"}"#.utf8), statusCode: 200))

        let none = try await CurationGateway.live(client: { negative }).fetchAllowance()
        let allowance = try await CurationGateway.live(client: { unlimited }).fetchAllowance()

        XCTAssertNil(none)
        XCTAssertEqual(allowance?.isUnlimited, true)
        XCTAssertNil(allowance?.remaining)
    }

    // verifies: ios-dec-99
    func testLivePassesApiFailureThroughUnchanged() async throws {
        let apiClient = client(session: MockURLSession(data: Data(), statusCode: 500))
        let gateway = CurationGateway.live(client: { apiClient })

        do {
            _ = try await gateway.fetchFeed()
            XCTFail("失敗は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }
}
