import XCTest
import Combine
@testable import NewsListenApp

// MARK: - test double（このファイル専用）

/// `PreferencesGateway` の fake。`update`・`fetch` の呼出を記録し、結果を「即時成功／即時の error／保留」で返す。
/// 保留は `CheckedContinuation` で持ち、テストが `resumePending` で成功・失敗を後から返す（`Task.sleep` は使わない）。
private final class FakeGateway: @unchecked Sendable {
    enum Outcome {
        case success
        case failure(Error)
        case pending
    }

    private let lock = NSLock()
    private var outcomes: [Outcome] = []
    private var defaultOutcome: Outcome = .success
    private var fetchOutcomes: [Result<PreferenceValues, Error>] = []
    private var defaultFetch: Result<PreferenceValues, Error> = .success(PreferenceValues(difficulty: nil, playbackSpeed: nil, weeklyGoal: nil))
    private var recordedUpdates: [PreferenceChange] = []
    private var recordedFetchCount = 0
    private var pendingContinuations: [CheckedContinuation<Void, Error>] = []
    private var pendingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var updates: [PreferenceChange] { lock.withLock { recordedUpdates } }
    var fetchCount: Int { lock.withLock { recordedFetchCount } }

    /// `update` の結果を呼出順に与える。尽きたら `defaultOutcome`。
    func enqueue(_ outcomes: Outcome...) { lock.withLock { self.outcomes.append(contentsOf: outcomes) } }
    func setDefault(_ outcome: Outcome) { lock.withLock { defaultOutcome = outcome } }
    func enqueueFetch(_ results: Result<PreferenceValues, Error>...) { lock.withLock { fetchOutcomes.append(contentsOf: results) } }

    func update(_ change: PreferenceChange) async throws {
        let outcome: Outcome = lock.withLock {
            recordedUpdates.append(change)
            return outcomes.isEmpty ? defaultOutcome : outcomes.removeFirst()
        }
        switch outcome {
        case .success:
            return
        case .failure(let error):
            throw error
        case .pending:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
                    pendingContinuations.append(continuation)
                    let satisfied = pendingWaiters.filter { $0.count <= pendingContinuations.count }
                    pendingWaiters.removeAll { $0.count <= pendingContinuations.count }
                    return satisfied.map(\.continuation)
                }
                ready.forEach { $0.resume() }
            }
        }
    }

    func fetch() async throws -> PreferenceValues {
        let result: Result<PreferenceValues, Error> = lock.withLock {
            recordedFetchCount += 1
            return fetchOutcomes.isEmpty ? defaultFetch : fetchOutcomes.removeFirst()
        }
        return try result.get()
    }

    /// 保留した `update` が `count` 件に達するまで待つ。
    func waitForPending(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached: Bool = lock.withLock {
                if pendingContinuations.count >= count { return true }
                pendingWaiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    /// `index` 番目（到着順）に保留した `update` を、成功（error なし）か失敗で解放する。
    func resumePending(_ index: Int, throwing error: Error? = nil) {
        let continuation: CheckedContinuation<Void, Error> = lock.withLock { pendingContinuations[index] }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    var gateway: PreferencesGateway {
        PreferencesGateway(fetch: { try await self.fetch() }, update: { try await self.update($0) })
    }
}

/// `PreferenceStorage` の fake。メモリ上のスナップショットを `read` で返し、`write` と `clearSubjectScoped` を記録する。
private final class FakeStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PreferenceSnapshot
    private var recordedWrites: [StoredPreference] = []
    private var recordedClearCount = 0

    init(_ snapshot: PreferenceSnapshot) { self.snapshot = snapshot }

    var writes: [StoredPreference] { lock.withLock { recordedWrites } }
    var clearCount: Int { lock.withLock { recordedClearCount } }

    var storage: PreferenceStorage {
        PreferenceStorage(
            read: { self.lock.withLock { self.snapshot } },
            write: { value in self.lock.withLock { self.recordedWrites.append(value) } },
            clearSubjectScoped: { self.lock.withLock { self.recordedClearCount += 1 } }
        )
    }
}

private func defaultSnapshot() -> PreferenceSnapshot {
    PreferenceSnapshot(
        difficulty: .toeic600, playbackSpeed: 1.0, weeklyGoal: .default,
        articleOpenMode: .inApp, timeFormat: .absolute, soundEnabled: true, hapticsEnabled: true
    )
}

private func goal(_ episodes: Int) -> WeeklyGoalTarget { WeeklyGoalTarget(episodes: episodes)! }

private func alice(_ token: String = "tA") -> LoginReceipt {
    LoginReceipt(token: token, subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil))
}

private func bob() -> LoginReceipt {
    LoginReceipt(token: "tB", subject: Subject(username: "bob", displayName: "Bob", role: Role(rawValue: "user"), key: nil))
}

private let server500 = ApiFailure.server(status: 500)

/// store・主体の源（実物の `AppState`）・fake を束ねる。
/// `SubjectStamp` はテストから作れない（`fileprivate`）ので、主体は `AppState` の `completeLogin`/`logout` で動かす。
@MainActor
private struct Rig {
    let state: AppState
    let store: PreferencesStore
    let gateway: FakeGateway
    let storage: FakeStorage

    init(authenticated: Bool = true, snapshot: PreferenceSnapshot = defaultSnapshot(), hasGateway: Bool = true) {
        let sessionStore = InMemorySessionStore(token: authenticated ? "tA" : nil)
        let state = makeSubjectAwareAppState(sessionStore: sessionStore)
        if authenticated { state.completeLogin(alice()) }
        let gateway = FakeGateway()
        let storage = FakeStorage(snapshot)
        self.state = state
        self.gateway = gateway
        self.storage = storage
        self.store = PreferencesStore(
            gateway: hasGateway ? gateway.gateway : nil,
            storage: storage.storage,
            isCurrentSubject: { state.isCurrentSubject($0) },
            subjectStamp: { state.subjectStamp },
            isAuthenticated: { state.currentSubject != nil }
        )
    }

    /// 実際の logout → login で主体を B に交代させる。
    func switchToBob() async {
        await state.logout()
        state.completeLogin(bob())
    }

    /// B の後にさらに別の主体へ交代させる（同じトークンへの再ログインは同じ主体とみなされるため、別トークンにする）。
    func switchToCarol() async {
        await state.logout()
        state.completeLogin(LoginReceipt(token: "tC", subject: Subject(username: "carol", displayName: "Carol", role: Role(rawValue: "user"), key: nil)))
    }
}

private func capture(_ operation: () async throws -> Void) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

// MARK: - PreferencesStore のテスト

@MainActor
final class PreferencesStoreTests: XCTestCase {

    // MARK: init

    // verifies: ios-model-prefs
    func testInitReflectsStoredSnapshot() {
        let snapshot = PreferenceSnapshot(
            difficulty: .ielts7, playbackSpeed: 1.5, weeklyGoal: goal(7),
            articleOpenMode: .external, timeFormat: .relative, soundEnabled: false, hapticsEnabled: false
        )
        let rig = Rig(snapshot: snapshot)

        XCTAssertEqual(rig.store.defaultDifficulty, .ielts7)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(rig.store.weeklyGoal, goal(7))
        XCTAssertEqual(rig.store.articleOpenMode, .external)
        XCTAssertEqual(rig.store.timeFormat, .relative)
        XCTAssertFalse(rig.store.soundEnabled)
        XCTAssertFalse(rig.store.hapticsEnabled)
        XCTAssertFalse(rig.store.syncFailed)
        XCTAssertTrue(rig.storage.writes.isEmpty)
        XCTAssertTrue(rig.gateway.updates.isEmpty)
        XCTAssertEqual(rig.gateway.fetchCount, 0)
    }

    // 旧 AppStateDefaultsTests.testDefaultDifficultyIsToeic600WhenUnset の移動先
    func testDefaultDifficultyIsToeic600WhenUnset() {
        let suite = UserDefaults(suiteName: "PreferencesStoreTests.\(UUID().uuidString)")!
        let (_, store) = makeAppStateWithPreferences(defaults: suite)

        XCTAssertEqual(store.defaultDifficulty, .toeic600)
    }

    // MARK: 認証外の set*（ios-rule-prefs-04・ios-rule-prefs-05）

    // verifies: ios-rule-prefs-04
    func testSyncedSettersWhileNotAuthenticatedResetToDefaultsWithoutWritingOrSending() async {
        let snapshot = PreferenceSnapshot(
            difficulty: .ielts7, playbackSpeed: 1.5, weeklyGoal: goal(7),
            articleOpenMode: .inApp, timeFormat: .absolute, soundEnabled: true, hapticsEnabled: true
        )
        let rig = Rig(authenticated: false, snapshot: snapshot)

        let e1 = await capture { try await rig.store.setDefaultDifficulty(.toeic900) }
        let e2 = await capture { try await rig.store.setDefaultPlaybackSpeed(1.25) }
        let e3 = await capture { try await rig.store.setWeeklyGoal(goal(5)) }

        XCTAssertNil(e1)
        XCTAssertNil(e2)
        XCTAssertNil(e3)
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(rig.store.weeklyGoal, .default)
        XCTAssertTrue(rig.storage.writes.isEmpty)
        XCTAssertTrue(rig.gateway.updates.isEmpty)
    }

    // MARK: 同期 set* の成功（ios-cmd-prefs-01）

    // verifies: ios-cmd-prefs-01
    func testSetDefaultDifficultySucceedsAndWritesAndSendsOnce() async throws {
        let rig = Rig()

        try await rig.store.setDefaultDifficulty(.toeic900)

        XCTAssertEqual(rig.store.defaultDifficulty, .toeic900)
        XCTAssertEqual(rig.storage.writes, [.difficulty(.toeic900)])
        XCTAssertEqual(rig.gateway.updates, [.difficulty(.toeic900)])
    }

    // verifies: ios-cmd-prefs-01
    func testSetDefaultPlaybackSpeedSucceedsAndWritesAndSendsOnce() async throws {
        let rig = Rig()

        try await rig.store.setDefaultPlaybackSpeed(1.25)

        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.25)
        XCTAssertEqual(rig.storage.writes, [.playbackSpeed(1.25)])
        XCTAssertEqual(rig.gateway.updates, [.playbackSpeed(1.25)])
    }

    // verifies: ios-cmd-prefs-01
    func testSetWeeklyGoalSucceedsAndRecordsConfirmedValue() async throws {
        let rig = Rig()

        try await rig.store.setWeeklyGoal(goal(5))
        try await rig.store.setWeeklyGoal(goal(5))

        XCTAssertEqual(rig.store.weeklyGoal, goal(5))
        XCTAssertEqual(rig.storage.writes.first, .weeklyGoal(goal(5)))
        XCTAssertEqual(rig.gateway.updates, [.weeklyGoal(goal(5))], "確認済みと同じ値の再呼出しは送らない")
    }

    // verifies: ios-cmd-prefs-01
    func testSettersWithoutGatewayTreatAsSuccess() async throws {
        let rig = Rig(hasGateway: false)

        try await rig.store.setDefaultDifficulty(.eiken2)
        try await rig.store.setDefaultPlaybackSpeed(1.5)
        try await rig.store.setWeeklyGoal(goal(10))

        XCTAssertEqual(rig.store.defaultDifficulty, .eiken2)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(rig.store.weeklyGoal, goal(10))
        XCTAssertEqual(rig.storage.writes, [.difficulty(.eiken2), .playbackSpeed(1.5), .weeklyGoal(goal(10))])
    }

    // 旧 testSyncDifficultySuccessMultipleTimes の移動先
    func testSetDefaultDifficultySuccessMultipleTimes() async throws {
        let rig = Rig()

        try await rig.store.setDefaultDifficulty(.toeic600)
        try await rig.store.setDefaultDifficulty(.toeic900)
        try await rig.store.setDefaultDifficulty(.ielts55)

        XCTAssertEqual(rig.store.defaultDifficulty, .ielts55)
        XCTAssertEqual(rig.gateway.updates.count, 3, "週の目標以外は同値でも毎回送る")
    }

    // MARK: 同期 set* の失敗（ios-rule-prefs-05）

    // verifies: ios-rule-prefs-05
    func testSetDefaultDifficultyFailureRollsBackAndRethrows() async {
        let rig = Rig()
        rig.gateway.setDefault(.failure(server500))

        let error = await capture { try await rig.store.setDefaultDifficulty(.toeic900) }

        XCTAssertEqual(error as? ApiFailure, server500)
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
        XCTAssertEqual(rig.storage.writes, [.difficulty(.toeic900), .difficulty(.toeic600)])
    }

    // verifies: ios-rule-prefs-05
    func testSetDefaultPlaybackSpeedFailureRollsBackAndRethrows() async {
        let rig = Rig()
        rig.gateway.setDefault(.failure(server500))

        let error = await capture { try await rig.store.setDefaultPlaybackSpeed(1.5) }

        XCTAssertEqual(error as? ApiFailure, server500)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(rig.storage.writes, [.playbackSpeed(1.5), .playbackSpeed(1.0)])
    }

    // 旧 testSyncWeeklyGoalFailureMessage の移動先。失敗した値は確認済みにしない（ios-dec-96）
    // verifies: ios-rule-prefs-05
    func testSetWeeklyGoalFailureRollsBackAndDoesNotConfirmFailedValue() async throws {
        let rig = Rig()
        rig.gateway.enqueue(.failure(server500), .success)

        let error = await capture { try await rig.store.setWeeklyGoal(goal(5)) }
        XCTAssertEqual(error as? ApiFailure, server500)
        XCTAssertEqual(rig.store.weeklyGoal, .default)
        XCTAssertEqual(rig.storage.writes, [.weeklyGoal(goal(5)), .weeklyGoal(.default)])

        try await rig.store.setWeeklyGoal(goal(5))

        XCTAssertEqual(rig.gateway.updates, [.weeklyGoal(goal(5)), .weeklyGoal(goal(5))], "失敗した 5 は確認済みではないので、選び直すと送る")
    }

    // 巻き戻しは update を再送しない（ios-dec-97）
    // verifies: ios-rule-prefs-05
    func testRollbackDoesNotResendUpdate() async {
        let rig = Rig()
        rig.gateway.setDefault(.failure(server500))

        _ = await capture { try await rig.store.setDefaultDifficulty(.toeic900) }
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(rig.gateway.updates, [.difficulty(.toeic900)])
    }

    // verifies: ios-rule-prefs-05
    func testCancellationFailureIsRethrownAndRolledBack() async {
        let rig = Rig()
        rig.gateway.setDefault(.failure(CancellationError()))

        let e1 = await capture { try await rig.store.setDefaultDifficulty(.toeic900) }
        let e2 = await capture { try await rig.store.setDefaultPlaybackSpeed(1.5) }
        let e3 = await capture { try await rig.store.setWeeklyGoal(goal(5)) }

        XCTAssertTrue(e1 is CancellationError)
        XCTAssertTrue(e2 is CancellationError)
        XCTAssertTrue(e3 is CancellationError)
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(rig.store.weeklyGoal, .default)
    }

    private struct OtherError: Error, Equatable {}

    // verifies: ios-rule-prefs-05
    func testArbitraryErrorIsRethrownUnchangedAndRolledBack() async {
        let rig = Rig()
        rig.gateway.setDefault(.failure(OtherError()))

        let error = await capture { try await rig.store.setDefaultDifficulty(.eiken2) }

        XCTAssertEqual(error as? OtherError, OtherError())
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
    }

    // 旧 testSyncDifficultyMultipleRequestsLastWins の移動先
    func testDifficultyFailureThenSuccessLastWins() async throws {
        let rig = Rig()
        rig.gateway.enqueue(.failure(server500), .success)

        let first = await capture { try await rig.store.setDefaultDifficulty(.toeic900) }
        XCTAssertNotNil(first)
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)

        try await rig.store.setDefaultDifficulty(.toeic900)

        XCTAssertEqual(rig.store.defaultDifficulty, .toeic900)
    }

    // 旧 testSyncPlaybackSpeedMultipleRequestsLastWins の移動先
    func testPlaybackSpeedFailureThenSuccessLastWins() async throws {
        let rig = Rig()
        rig.gateway.enqueue(.failure(server500), .success)

        let first = await capture { try await rig.store.setDefaultPlaybackSpeed(1.25) }
        XCTAssertNotNil(first)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.0)

        try await rig.store.setDefaultPlaybackSpeed(1.5)

        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.5)
    }

    // 古い失敗は巻き戻さない（最新の失敗は巻き戻す）が、どちらも error は投げる
    // verifies: ios-rule-prefs-05
    func testStaleFailureDoesNotRollBackButStillThrows() async {
        let rig = Rig()
        rig.gateway.enqueue(.pending, .failure(server500))

        // A(toeic600) → B(toeic900) を保留
        let first = Task { await capture { try await rig.store.setDefaultDifficulty(.toeic900) } }
        await rig.gateway.waitForPending(1)
        // B → C(ielts7) は即時失敗。最新なので B へ戻る
        let latest = await capture { try await rig.store.setDefaultDifficulty(.ielts7) }
        XCTAssertEqual(latest as? ApiFailure, server500)
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic900, "最新の失敗は 1 つ前の値 B へ巻き戻す")

        // 古い B の失敗を解放する
        rig.gateway.resumePending(0, throwing: server500)
        let stale = await first.value

        XCTAssertEqual(stale as? ApiFailure, server500, "古い失敗も error は投げる")
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic900, "古い失敗は巻き戻さない（A へ戻らない）")
        XCTAssertEqual(rig.storage.writes.last, .difficulty(.toeic900))
    }

    // 旧 testSyncWeeklyGoalStaleFailureIgnored の移動先
    func testConcurrentWeeklyGoalRequestsAtLeastOneSucceeds() async {
        let rig = Rig()
        rig.gateway.enqueue(.failure(server500), .success)

        let task1 = Task { await capture { try await rig.store.setWeeklyGoal(goal(5)) } }
        let task2 = Task { await capture { try await rig.store.setWeeklyGoal(goal(7)) } }
        let e1 = await task1.value
        let e2 = await task2.value

        XCTAssertTrue(e1 == nil || e2 == nil, "少なくとも 1 つは throw しない")
    }

    // 古い要求の失敗で、失敗した値を確認済みにしない（ios-dec-96）
    // verifies: ios-dec-96
    func testStaleFailureDoesNotConfirmFailedWeeklyGoal() async throws {
        let rig = Rig()
        rig.gateway.enqueue(.pending, .success, .success)

        let req5 = Task { await capture { try await rig.store.setWeeklyGoal(goal(5)) } }
        await rig.gateway.waitForPending(1)
        try await rig.store.setWeeklyGoal(goal(7))
        rig.gateway.resumePending(0, throwing: server500)
        let stale = await req5.value
        XCTAssertNotNil(stale)
        XCTAssertEqual(rig.store.weeklyGoal, goal(7), "古い失敗は巻き戻さない")

        try await rig.store.setWeeklyGoal(goal(5))

        XCTAssertEqual(
            rig.gateway.updates,
            [.weeklyGoal(goal(5)), .weeklyGoal(goal(7)), .weeklyGoal(goal(5))],
            "確認済みは 7 のままなので、5 を選び直すと送られる"
        )
    }

    // 旧 testSyncWeeklyGoalMultipleSuccessNoLoop の移動先
    func testWeeklyGoalSuccessiveSuccessesSendOnlyWhenChanged() async throws {
        let rig = Rig()

        try await rig.store.setWeeklyGoal(goal(5))
        try await rig.store.setWeeklyGoal(goal(5))
        try await rig.store.setWeeklyGoal(goal(7))
        try await rig.store.setWeeklyGoal(goal(3))

        XCTAssertEqual(rig.gateway.updates, [.weeklyGoal(goal(5)), .weeklyGoal(goal(7)), .weeklyGoal(goal(3))])
        XCTAssertEqual(rig.store.weeklyGoal, goal(3))
    }

    // MARK: 主体ガード（ios-rule-prefs-05）

    // verifies: ios-rule-prefs-05
    func testSuccessAfterSubjectChangeDoesNotConfirmWeeklyGoal() async throws {
        let rig = Rig()
        rig.gateway.enqueue(.pending, .success)

        let task = Task { await capture { try await rig.store.setWeeklyGoal(goal(5)) } }
        await rig.gateway.waitForPending(1)
        await rig.switchToBob()
        rig.gateway.resumePending(0)
        let error = await task.value
        XCTAssertNil(error)
        XCTAssertEqual(rig.storage.writes, [.weeklyGoal(goal(5))], "前の主体の応答で保存に触れない")

        try await rig.store.setWeeklyGoal(goal(5))

        XCTAssertEqual(rig.gateway.updates.count, 2, "前の主体の成功は確認済みにならない")
    }

    // verifies: ios-rule-prefs-05
    func testFailureAfterSubjectChangeDoesNotRollBackDifficulty() async {
        let rig = Rig()
        rig.gateway.enqueue(.pending)

        let task = Task { await capture { try await rig.store.setDefaultDifficulty(.toeic900) } }
        await rig.gateway.waitForPending(1)
        await rig.switchToBob()
        rig.gateway.resumePending(0, throwing: server500)
        let error = await task.value

        XCTAssertEqual(error as? ApiFailure, server500, "主体が変わっていても error は投げ直す")
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic900, "巻き戻さない")
        XCTAssertEqual(rig.storage.writes, [.difficulty(.toeic900)])
    }

    // verifies: ios-rule-prefs-05
    func testFailureAfterSubjectChangeDoesNotRollBackPlaybackSpeedAndWeeklyGoal() async {
        let rig = Rig()
        rig.gateway.enqueue(.pending, .pending)

        let speed = Task { await capture { try await rig.store.setDefaultPlaybackSpeed(1.5) } }
        await rig.gateway.waitForPending(1)
        let weekly = Task { await capture { try await rig.store.setWeeklyGoal(goal(5)) } }
        await rig.gateway.waitForPending(2)
        await rig.switchToBob()
        rig.gateway.resumePending(0, throwing: server500)
        rig.gateway.resumePending(1, throwing: server500)
        let speedError = await speed.value
        let weeklyError = await weekly.value

        XCTAssertNotNil(speedError)
        XCTAssertNotNil(weeklyError)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(rig.store.weeklyGoal, goal(5))
        XCTAssertEqual(rig.storage.writes, [.playbackSpeed(1.5), .weeklyGoal(goal(5))])
    }

    // 旧 AppStateAuthTests.testTT14_23_confirmWeeklyGoalSyncGuardedBySubject の移動先
    // verifies: ios-contract-20.18
    func testWeeklyGoalConfirmationIsGuardedBySubject() async throws {
        let rig = Rig()
        rig.gateway.enqueue(.pending, .success, .success)

        // A が 5 を送って保留
        let task = Task { await capture { try await rig.store.setWeeklyGoal(goal(5)) } }
        await rig.gateway.waitForPending(1)
        // B がログインしてから A の応答（成功）が返る
        await rig.switchToBob()
        rig.gateway.resumePending(0)
        _ = await task.value

        // B が 5 を選ぶ → A の確認は B に及ばないので送られる
        try await rig.store.setWeeklyGoal(goal(5))
        XCTAssertEqual(rig.gateway.updates.count, 2)

        // B 自身の成功は B の確認済みになる → 再度 5 を選んでも送られない
        try await rig.store.setWeeklyGoal(goal(5))
        XCTAssertEqual(rig.gateway.updates.count, 2)
    }

    // MARK: 速度の範囲外（ios-rule-prefs-06）

    // verifies: ios-rule-prefs-06
    func testOutOfRangePlaybackSpeedIsIgnored() async {
        let rig = Rig()

        let e1 = await capture { try await rig.store.setDefaultPlaybackSpeed(3.0) }
        let e2 = await capture { try await rig.store.setDefaultPlaybackSpeed(0.0) }

        XCTAssertNil(e1)
        XCTAssertNil(e2)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.0)
        XCTAssertTrue(rig.storage.writes.isEmpty)
        XCTAssertTrue(rig.gateway.updates.isEmpty)
    }

    // MARK: 端末設定（ios-cmd-prefs-02。ios-test-019）

    // verifies: ios-cmd-prefs-02
    func testDeviceLocalSettersWriteWithoutTouchingGatewayRegardlessOfAuthentication() {
        for authenticated in [true, false] {
            let rig = Rig(authenticated: authenticated)

            rig.store.setArticleOpenMode(.external)
            rig.store.setTimeFormat(.relative)
            rig.store.setSoundEnabled(false)
            rig.store.setHapticsEnabled(false)

            XCTAssertEqual(rig.store.articleOpenMode, .external, "authenticated=\(authenticated)")
            XCTAssertEqual(rig.store.timeFormat, .relative)
            XCTAssertFalse(rig.store.soundEnabled)
            XCTAssertFalse(rig.store.hapticsEnabled)
            XCTAssertEqual(
                rig.storage.writes,
                [.articleOpenMode(.external), .timeFormat(.relative), .soundEnabled(false), .hapticsEnabled(false)]
            )
            XCTAssertTrue(rig.gateway.updates.isEmpty)
            XCTAssertEqual(rig.gateway.fetchCount, 0)
        }
    }

    // MARK: clearSubjectScoped（ios-cmd-prefs-03。ios-test-020・ios-contract-23）

    // verifies: ios-cmd-prefs-03
    func testClearSubjectScopedResetsSubjectValuesOnly() async throws {
        let snapshot = PreferenceSnapshot(
            difficulty: .ielts7, playbackSpeed: 1.5, weeklyGoal: goal(7),
            articleOpenMode: .external, timeFormat: .relative, soundEnabled: false, hapticsEnabled: false
        )
        let rig = Rig(snapshot: snapshot)
        rig.gateway.enqueueFetch(.failure(server500))
        await rig.store.refreshFromServer()
        XCTAssertTrue(rig.store.syncFailed)

        rig.store.clearSubjectScoped()

        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(rig.store.weeklyGoal, .default)
        XCTAssertEqual(rig.store.articleOpenMode, .external)
        XCTAssertEqual(rig.store.timeFormat, .relative)
        XCTAssertFalse(rig.store.soundEnabled)
        XCTAssertFalse(rig.store.hapticsEnabled)
        XCTAssertTrue(rig.store.syncFailed, "syncFailed は触らない")
        XCTAssertEqual(rig.storage.clearCount, 1)
        XCTAssertTrue(rig.gateway.updates.isEmpty)

        try await rig.store.setWeeklyGoal(.default)
        XCTAssertTrue(rig.gateway.updates.isEmpty, "確認済みも既定へ戻る（3 は送らない）")
        try await rig.store.setWeeklyGoal(goal(7))
        XCTAssertEqual(rig.gateway.updates, [.weeklyGoal(goal(7))], "7 はもう確認済みではない")
    }

    // verifies: ios-contract-23
    func testClearSubjectScopedRemovesFourKeysAndKeepsDeviceKeysViaLiveStorage() {
        let suite = UserDefaults(suiteName: "PreferencesStoreTests.\(UUID().uuidString)")!
        suite.set("toeic_900", forKey: "default_difficulty")
        suite.set(1.25, forKey: "default_playback_speed")
        suite.set(5, forKey: "weekly_goal_episodes")
        suite.set(["a1"], forKey: "seen_achievement_ids")
        suite.set("external", forKey: "article_open_mode")
        suite.set("relative", forKey: "time_format")
        suite.set(false, forKey: "sfx_enabled")
        suite.set(false, forKey: "haptics_enabled")
        let (_, store) = makeAppStateWithPreferences(defaults: suite)

        store.clearSubjectScoped()
        store.clearSubjectScoped()

        for key in ["default_difficulty", "default_playback_speed", "weekly_goal_episodes", "seen_achievement_ids"] {
            XCTAssertNil(suite.object(forKey: key), "\(key) は消える")
        }
        for key in ["article_open_mode", "time_format", "sfx_enabled", "haptics_enabled"] {
            XCTAssertNotNil(suite.object(forKey: key), "\(key) は残る")
        }
    }

    // MARK: refreshFromServer（ios-cmd-prefs-04。ios-test-034）

    private func values(_ difficulty: DifficultyLevel?, _ speed: Double?, _ weekly: Int?) -> PreferenceValues {
        PreferenceValues(difficulty: difficulty, playbackSpeed: speed, weeklyGoal: weekly.flatMap { WeeklyGoalTarget(episodes: $0) })
    }

    // 旧 testRefreshPreferencesClearsFailedFlagOnSuccess の移動先
    // verifies: ios-cmd-prefs-04
    func testRefreshFromServerClearsFailedFlagOnSuccess() async throws {
        let snapshot = PreferenceSnapshot(
            difficulty: .ielts7, playbackSpeed: 1.5, weeklyGoal: .default,
            articleOpenMode: .inApp, timeFormat: .absolute, soundEnabled: true, hapticsEnabled: true
        )
        let rig = Rig(snapshot: snapshot)
        rig.gateway.enqueueFetch(.failure(server500), .success(values(.toeic600, 1.25, 7)))
        await rig.store.refreshFromServer()
        XCTAssertTrue(rig.store.syncFailed)

        await rig.store.refreshFromServer()

        XCTAssertFalse(rig.store.syncFailed)
        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.25)
        XCTAssertEqual(rig.store.weeklyGoal, goal(7))
        XCTAssertEqual(rig.storage.writes, [.difficulty(.toeic600), .playbackSpeed(1.25), .weeklyGoal(goal(7))])
        XCTAssertTrue(rig.gateway.updates.isEmpty, "取得はサーバーへ書かない")

        try await rig.store.setWeeklyGoal(goal(7))
        XCTAssertTrue(rig.gateway.updates.isEmpty, "取得した週の目標は確認済みになる")
    }

    // 値が無い項目は現在値・保存とも変えない
    // verifies: ios-cmd-prefs-04
    func testRefreshFromServerLeavesAbsentItemsUntouched() async {
        let rig = Rig()
        rig.gateway.enqueueFetch(.success(values(nil, 1.5, nil)))

        await rig.store.refreshFromServer()

        XCTAssertEqual(rig.store.defaultDifficulty, .toeic600)
        XCTAssertEqual(rig.store.weeklyGoal, .default)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(rig.storage.writes, [.playbackSpeed(1.5)])
    }

    // 旧 testRefreshPreferencesSetsFailedFlagOnFailure の移動先
    // verifies: ios-cmd-prefs-04
    func testRefreshFromServerSetsFailedFlagOnFailure() async {
        let rig = Rig()
        rig.gateway.enqueueFetch(.failure(server500))

        await rig.store.refreshFromServer()

        XCTAssertTrue(rig.store.syncFailed)
    }

    // 旧 testRefreshPreferencesPreservesLocalValueOnFailure の移動先
    func testRefreshFromServerPreservesLocalValueOnFailure() async {
        let snapshot = PreferenceSnapshot(
            difficulty: .ielts7, playbackSpeed: 1.5, weeklyGoal: goal(7),
            articleOpenMode: .inApp, timeFormat: .absolute, soundEnabled: true, hapticsEnabled: true
        )
        let rig = Rig(snapshot: snapshot)
        rig.gateway.enqueueFetch(.failure(server500))

        await rig.store.refreshFromServer()

        XCTAssertEqual(rig.store.defaultDifficulty, .ielts7)
        XCTAssertEqual(rig.store.defaultPlaybackSpeed, 1.5)
        XCTAssertEqual(rig.store.weeklyGoal, goal(7))
        XCTAssertTrue(rig.storage.writes.isEmpty)
    }

    // verifies: ios-cmd-prefs-04
    func testRefreshFromServerWhileNotAuthenticatedDoesNothing() async {
        let rig = Rig(authenticated: false)

        await rig.store.refreshFromServer()

        XCTAssertEqual(rig.gateway.fetchCount, 0)
        XCTAssertFalse(rig.store.syncFailed)
        XCTAssertTrue(rig.storage.writes.isEmpty)
    }

    // verifies: ios-cmd-prefs-04
    func testRefreshFromServerCancellationIsNotAFailure() async {
        let rig = Rig()
        rig.gateway.enqueueFetch(.failure(CancellationError()), .failure(server500), .failure(CancellationError()))

        await rig.store.refreshFromServer()
        XCTAssertFalse(rig.store.syncFailed, "キャンセルは失敗にしない")

        await rig.store.refreshFromServer()
        XCTAssertTrue(rig.store.syncFailed)

        await rig.store.refreshFromServer()
        XCTAssertTrue(rig.store.syncFailed, "キャンセルは既存の失敗の印を変えない")
    }

    // 応答前に主体が変わったら、成功でも失敗でも何も書かない
    // verifies: ios-cmd-prefs-04
    func testRefreshFromServerDiscardsResultAfterSubjectChange() async {
        let rig = Rig()
        let storage = FakeStorage(defaultSnapshot())
        let pendingFetch = PendingFetch()
        let state = rig.state
        let store = PreferencesStore(
            gateway: PreferencesGateway(fetch: { try await pendingFetch.wait() }, update: { _ in }),
            storage: storage.storage,
            isCurrentSubject: { state.isCurrentSubject($0) },
            subjectStamp: { state.subjectStamp },
            isAuthenticated: { state.currentSubject != nil }
        )

        let task = Task { await store.refreshFromServer() }
        await pendingFetch.waitUntilStarted()
        await rig.switchToBob()
        pendingFetch.finish(.success(values(.toeic900, 1.25, 5)))
        await task.value

        XCTAssertEqual(store.defaultDifficulty, .toeic600)
        XCTAssertTrue(storage.writes.isEmpty)
        XCTAssertFalse(store.syncFailed)

        let failing = Task { await store.refreshFromServer() }
        await pendingFetch.waitUntilStarted(count: 2)
        await rig.switchToCarol()
        pendingFetch.finish(.failure(server500))
        await failing.value
        XCTAssertFalse(store.syncFailed, "主体が変わった後の失敗は印を立てない")
    }
}

/// 呼出ごとに保留して、テストが結果を返す fetch。
private final class PendingFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<PreferenceValues, Error>] = []
    private var started = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async throws -> PreferenceValues {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreferenceValues, Error>) in
            let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
                continuations.append(continuation)
                started += 1
                let satisfied = startWaiters.filter { $0.count <= started }
                startWaiters.removeAll { $0.count <= started }
                return satisfied.map(\.continuation)
            }
            ready.forEach { $0.resume() }
        }
    }

    func waitUntilStarted(count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached: Bool = lock.withLock {
                if started >= count { return true }
                startWaiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    /// 最後に保留した fetch を解放する。
    func finish(_ result: Result<PreferenceValues, Error>) {
        let continuation: CheckedContinuation<PreferenceValues, Error> = lock.withLock { continuations.removeLast() }
        continuation.resume(with: result)
    }
}

// MARK: - 実物の gateway・registry を通す検査（ios-test-018 ほか）

@MainActor
final class PreferencesStoreLiveAdapterTests: XCTestCase {

    private let preferencesPath = "/settings/preferences"

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "PreferencesStoreTests.\(UUID().uuidString)")!
    }

    private func requestBody(_ session: MockURLSession) throws -> [String: Any] {
        let body = try XCTUnwrap(session.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // 送信 body の key と値が正しい。method は PUT
    // verifies: ios-cmd-prefs-01
    func testSuccessSendsOnlyTheChangedKeyWithPut() async throws {
        let session = MockURLSession(data: Data("{}".utf8), statusCode: 200)
        let suite = makeSuite()
        let (state, store) = makeAppStateWithPreferences(session: session, sessionStore: InMemorySessionStore(token: "tA"), defaults: suite)
        state.completeLogin(alice())

        try await store.setDefaultDifficulty(.toeic900)
        XCTAssertEqual(session.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(session.lastRequest?.url?.path, preferencesPath)
        let difficultyBody = try requestBody(session)
        XCTAssertEqual(difficultyBody["default_difficulty"] as? String, "toeic_900")
        XCTAssertNil(difficultyBody["default_playback_speed"])
        XCTAssertNil(difficultyBody["weekly_goal_episodes"])

        try await store.setDefaultPlaybackSpeed(1.25)
        let speedBody = try requestBody(session)
        XCTAssertEqual(speedBody["default_playback_speed"] as? Double, 1.25)
        XCTAssertNil(speedBody["default_difficulty"])

        try await store.setWeeklyGoal(goal(5))
        let goalBody = try requestBody(session)
        XCTAssertEqual(goalBody["weekly_goal_episodes"] as? Int, 5)
        XCTAssertNil(goalBody["default_difficulty"])

        XCTAssertEqual(suite.string(forKey: "default_difficulty"), "toeic_900")
        XCTAssertEqual(suite.double(forKey: "default_playback_speed"), 1.25)
        XCTAssertEqual(suite.integer(forKey: "weekly_goal_episodes"), 5)
    }

    // verifies: ios-rule-prefs-05
    func testServerErrorRollsBackStoreAndSavedValue() async {
        let session = MockURLSession(data: Data(), statusCode: 500)
        let suite = makeSuite()
        let (state, store) = makeAppStateWithPreferences(session: session, sessionStore: InMemorySessionStore(token: "tA"), defaults: suite)
        state.completeLogin(alice())

        let error = await capture { try await store.setDefaultDifficulty(.toeic900) }

        XCTAssertTrue(error is ApiFailure)
        XCTAssertEqual(store.defaultDifficulty, .toeic600)
        XCTAssertEqual(suite.string(forKey: "default_difficulty"), "toeic_600")
    }

    // 応答前に主体が変わる（実際の logout → login）→ 成功でも確認済みにしない
    // verifies: ios-rule-prefs-05
    func testSubjectChangeBeforeResponseIsNotConfirmedViaLiveGateway() async throws {
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "PUT", path: preferencesPath)
        let (state, store) = makeAppStateWithPreferences(session: scripted, sessionStore: InMemorySessionStore(token: "tA"), defaults: makeSuite())
        state.completeLogin(alice())

        let task = Task { await capture { try await store.setWeeklyGoal(goal(5)) } }
        await scripted.waitUntilRequested(method: "PUT", path: preferencesPath)
        await state.logout()
        state.completeLogin(bob())
        scripted.release(method: "PUT", path: preferencesPath, status: 200, body: Data("{}".utf8))
        let first = await task.value
        XCTAssertNil(first)

        scripted.configure(method: "PUT", path: preferencesPath, status: 200, body: Data("{}".utf8))
        try await store.setWeeklyGoal(goal(5))

        let puts = scripted.sentRequests.filter { $0.httpMethod == "PUT" && $0.url?.path == preferencesPath }
        XCTAssertEqual(puts.count, 2, "前の主体の成功は確認済みにならないので、B の 5 も送られる")
    }

    // 古い失敗は巻き戻さないが投げる
    // verifies: ios-rule-prefs-05
    func testStaleFailureViaLiveGatewayDoesNotRollBack() async {
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "PUT", path: preferencesPath)
        let (state, store) = makeAppStateWithPreferences(session: scripted, sessionStore: InMemorySessionStore(token: "tA"), defaults: makeSuite())
        state.completeLogin(alice())

        let first = Task { await capture { try await store.setDefaultDifficulty(.toeic900) } }
        await scripted.waitUntilRequested(method: "PUT", path: preferencesPath)
        scripted.configure(method: "PUT", path: preferencesPath, status: 500)
        let latest = await capture { try await store.setDefaultDifficulty(.ielts7) }
        XCTAssertTrue(latest is ApiFailure)
        XCTAssertEqual(store.defaultDifficulty, .toeic900)

        scripted.release(method: "PUT", path: preferencesPath, status: 500, body: Data())
        let stale = await first.value

        XCTAssertTrue(stale is ApiFailure)
        XCTAssertEqual(store.defaultDifficulty, .toeic900, "古い失敗は巻き戻さない")
    }

    // キャンセルも同じ（最新なら巻き戻し、error は投げる）
    // verifies: ios-rule-prefs-05
    func testCancellationViaLiveGatewayRollsBackAndThrows() async {
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "PUT", path: preferencesPath)
        let (state, store) = makeAppStateWithPreferences(session: scripted, sessionStore: InMemorySessionStore(token: "tA"), defaults: makeSuite())
        state.completeLogin(alice())

        let task = Task { await capture { try await store.setDefaultDifficulty(.toeic900) } }
        await scripted.waitUntilRequested(method: "PUT", path: preferencesPath)
        task.cancel()
        let error = await task.value

        XCTAssertNotNil(error)
        XCTAssertEqual(store.defaultDifficulty, .toeic600)
    }

    // 取得した DTO は、値域の内だけが PreferenceValues に残る
    // verifies: ios-cmd-prefs-04
    func testFetchKeepsOnlyInRangeValues() async throws {
        func fetch(_ json: String) async throws -> PreferenceValues {
            let session = MockURLSession(data: Data(json.utf8), statusCode: 200)
            let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
            return try await PreferencesGateway.live(client: { client }).fetch()
        }

        let valid = try await fetch(#"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":5}"#)
        XCTAssertEqual(valid, PreferenceValues(difficulty: .toeic900, playbackSpeed: 1.25, weeklyGoal: goal(5)))

        let invalid = try await fetch(#"{"default_difficulty":"x","default_playback_speed":3.0,"weekly_goal_episodes":4}"#)
        XCTAssertEqual(invalid, PreferenceValues(difficulty: nil, playbackSpeed: nil, weeklyGoal: nil))

        let empty = try await fetch("{}")
        XCTAssertEqual(empty, PreferenceValues(difficulty: nil, playbackSpeed: nil, weeklyGoal: nil))
    }

    // 値域外のサーバー値は、現在値にも保存にも入らない
    // verifies: ios-cmd-prefs-04
    func testRefreshIgnoresOutOfRangeServerValuesViaLiveGateway() async {
        let suite = makeSuite()
        let json = #"{"default_difficulty":"x","default_playback_speed":3.0,"weekly_goal_episodes":4}"#
        let session = MockURLSession(data: Data(json.utf8), statusCode: 200)
        let (state, store) = makeAppStateWithPreferences(session: session, sessionStore: InMemorySessionStore(token: "tA"), defaults: suite)
        state.completeLogin(alice())

        await store.refreshFromServer()

        XCTAssertEqual(store.defaultDifficulty, .toeic600)
        XCTAssertEqual(store.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(store.weeklyGoal, .default)
        XCTAssertFalse(store.syncFailed)
        for key in ["default_difficulty", "default_playback_speed", "weekly_goal_episodes"] {
            XCTAssertNil(suite.object(forKey: key), "\(key) は保存されない")
        }
    }

    // 保存の分類が PreferenceRegistry の subjectScopedKeys と一致する（ios-test-049）
    // verifies: ios-rule-prefs-04
    func testSubjectScopedCatalogMatchesRegistrySubjectScopedKeys() {
        let registry = PreferenceRegistry(defaults: makeSuite())
        let keyByItem: [PreferenceItem: String] = [
            .defaultDifficulty: "default_difficulty",
            .defaultPlaybackSpeed: "default_playback_speed",
            .weeklyGoal: "weekly_goal_episodes",
            .seenAchievements: "seen_achievement_ids",
        ]

        XCTAssertEqual(Set(PreferenceCatalog.subjectScoped.compactMap { keyByItem[$0] }), Set(registry.subjectScopedKeys))
        XCTAssertEqual(PreferenceCatalog.subjectScoped.count, registry.subjectScopedKeys.count)
    }
}

// MARK: - PATCH（更新要求）は利用者の変更からだけ（ios-dec-97）

@MainActor
final class PreferencesStoreUpdateOriginTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // verifies: ios-dec-97
    func testFailingDifficultyAndSpeedSendExactlyOneUpdateEachAndRollBackOnce() async {
        let recording = RecordingURLSession(delegate: MockURLSession(data: Data(), statusCode: 500))
        let (state, store) = makeAppStateWithPreferences(session: recording, sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(alice())
        var fired = 0
        store.objectWillChange.sink { fired += 1 }.store(in: &cancellables)
        recording.resetCounts()

        _ = await capture { try await store.setDefaultDifficulty(.toeic900) }
        await settle()
        XCTAssertEqual(recording.writeCount, 1)
        XCTAssertEqual(store.defaultDifficulty, .toeic600)

        recording.resetCounts()
        _ = await capture { try await store.setDefaultPlaybackSpeed(1.5) }
        await settle()
        XCTAssertEqual(recording.writeCount, 1)
        XCTAssertEqual(store.defaultPlaybackSpeed, 1.0)
        XCTAssertGreaterThan(fired, 0, "購読は発火している（発火しても更新は増えない）")
    }

    // 週の目標: 確認済みと巻き戻し先が違う組合せ（lastConfirmed != oldValue）でも再送しない
    // verifies: ios-dec-97
    func testFailingWeeklyGoalWithUnconfirmedOldValueDoesNotResend() async {
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "PUT", path: "/settings/preferences")
        let recording = RecordingURLSession(delegate: scripted)
        let suite = UserDefaults(suiteName: "PreferencesStoreTests.\(UUID().uuidString)")!
        suite.set(7, forKey: "weekly_goal_episodes")
        let (state, store) = makeAppStateWithPreferences(session: recording, sessionStore: InMemorySessionStore(token: "tA"), defaults: suite)
        state.completeLogin(alice())
        var fired = 0
        store.objectWillChange.sink { fired += 1 }.store(in: &cancellables)
        recording.resetCounts()

        // 確認済みは 7。5 を保留してから 10 を選ぶので、10 の旧値 5 は確認済みと違う
        let first = Task { await capture { try await store.setWeeklyGoal(goal(5)) } }
        await scripted.waitUntilRequested(method: "PUT", path: "/settings/preferences")
        scripted.configure(method: "PUT", path: "/settings/preferences", status: 500)
        _ = await capture { try await store.setWeeklyGoal(goal(10)) }
        XCTAssertEqual(store.weeklyGoal, goal(5), "10 の失敗は旧値 5 へ戻る")
        scripted.release(method: "PUT", path: "/settings/preferences", status: 500, body: Data())
        _ = await first.value
        await settle()

        XCTAssertEqual(recording.writeCount, 2, "要求ごとにちょうど 1 回。巻き戻しで再送しない")
        XCTAssertEqual(store.weeklyGoal, goal(5), "古い 5 の失敗は巻き戻さない")
        XCTAssertGreaterThan(fired, 0)
    }

    // 取得（購読者あり）・消去は更新要求を送らない
    // verifies: ios-dec-97
    func testRefreshAndClearSendNoWriteRequestsWithSubscriber() async {
        let json = #"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":5}"#
        let recording = RecordingURLSession(delegate: MockURLSession(data: Data(json.utf8), statusCode: 200))
        let (state, store) = makeAppStateWithPreferences(session: recording, sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(alice())
        var fired = 0
        store.objectWillChange.sink { fired += 1 }.store(in: &cancellables)
        recording.resetCounts()

        await store.refreshFromServer()
        await settle()
        XCTAssertEqual(store.defaultDifficulty, .toeic900, "取得した値は反映されている")
        XCTAssertEqual(recording.writeCount, 0)

        store.clearSubjectScoped()
        await settle()
        XCTAssertEqual(store.defaultDifficulty, .toeic600)
        XCTAssertEqual(recording.writeCount, 0)
        XCTAssertGreaterThan(fired, 0)
    }
}
