import XCTest
@testable import NewsListenApp

/// 呼出を保留し、テストが任意の時点で結果を与える補助。
///
/// 再開が登録より先でも結果を保持して完了する（捨てると呼出側が永久に待つ）。登録と結果の照合は
/// すべて `@MainActor` の上で行うので、通知と登録の間に窓ができない。
@MainActor
private final class Suspended<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var held: Result<Value, Error>?

    /// 保持済みの結果があればそれを返し、無ければ登録して再開を待つ。
    func suspend() async throws -> Value {
        if let result = held {
            held = nil
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// 登録済みなら再開し、未登録なら結果を保持する。
    func resume(with result: Result<Value, Error>) {
        if let registered = continuation {
            continuation = nil
            registered.resume(with: result)
        } else {
            held = result
        }
    }

    /// 登録されるまで上限つきで譲る。登録できたかを返す。
    func waitUntilSuspended() async -> Bool {
        for _ in 0..<1000 {
            if continuation != nil { return true }
            await Task.yield()
        }
        return continuation != nil
    }
}

private struct Boom: Error {}

private func alice() -> LoginReceipt {
    LoginReceipt(token: "tA", subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil))
}

private func bob() -> LoginReceipt {
    LoginReceipt(token: "tB", subject: Subject(username: "bob", displayName: "Bob", role: Role(rawValue: "user"), key: nil))
}

/// `OnboardingProgress` と、その主体の源（実物の `AppState`）、保留できる fetch・record を束ねる。
/// `SubjectStamp` はテストから作れない（`fileprivate`）ので、主体は `AppState` の `completeLogin`/`logout` で動かす。
@MainActor
private final class Rig {
    let sessionStore = InMemorySessionStore(token: "tA")
    let state: AppState
    let fetch = Suspended<Bool?>()
    let record = Suspended<Void>()
    private(set) var fetchCalls = 0
    private(set) var recordCalls = 0
    private(set) var progress: OnboardingProgress!

    init() {
        state = makeSubjectAwareAppState(sessionStore: sessionStore)
        state.completeLogin(alice())
        progress = OnboardingProgress(
            fetchStatus: { @MainActor [unowned self] in
                self.fetchCalls += 1
                return try await self.fetch.suspend()
            },
            recordCompleted: { @MainActor [unowned self] in
                self.recordCalls += 1
                try await self.record.suspend()
            },
            subjectStamp: { [unowned self] in self.state.subjectStamp },
            isCurrentSubject: { [unowned self] in self.state.isCurrentSubject($0) }
        )
    }

    /// 実際の logout → login で主体を B に交代させる。
    func switchToBob() async {
        await state.logout()
        state.completeLogin(bob())
    }
}

@MainActor
final class OnboardingProgressTests: XCTestCase {

    /// 取得と記録をその場で返す `OnboardingProgress`。主体は変わらない。
    private func makeProgress(
        fetch: @escaping () async throws -> Bool?,
        record: @escaping () async throws -> Void = {}
    ) -> OnboardingProgress {
        let state = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(alice())
        return OnboardingProgress(
            fetchStatus: fetch,
            recordCompleted: record,
            subjectStamp: { state.subjectStamp },
            isCurrentSubject: { state.isCurrentSubject($0) }
        )
    }

    // MARK: - 状態

    // verifies: ios-query-sources-02
    func testIsCompletedIsNilRightAfterInit() {
        let progress = makeProgress(fetch: { true })

        XCTAssertNil(progress.isCompleted)
    }

    // verifies: ios-query-sources-02
    func testRefreshStoresFetchedValue() async {
        for value in [false, true] {
            let progress = makeProgress(fetch: { value })

            await progress.refresh()

            XCTAssertEqual(progress.isCompleted, value)
        }
    }

    // verifies: ios-test-051, ios-rule-sources-03
    func testRefreshFailureIsTreatedAsCompleted() async {
        let progress = makeProgress(fetch: { throw Boom() })

        await progress.refresh()

        XCTAssertEqual(progress.isCompleted, true)
    }

    // verifies: ios-test-051
    func testRefreshWithNilStatusWritesNothing() async {
        let unfetched = makeProgress(fetch: { nil })
        await unfetched.refresh()
        XCTAssertNil(unfetched.isCompleted)

        var answer: Bool? = false
        let known = makeProgress(fetch: { answer })
        await known.refresh()
        XCTAssertEqual(known.isCompleted, false)
        answer = nil
        await known.refresh()
        XCTAssertEqual(known.isCompleted, false, "nil は既存の値を書き換えない")
    }

    // verifies: ios-cmd-sources-03
    func testCompleteRecordsOnceAndMarksCompleted() async {
        var recorded = 0
        let progress = makeProgress(fetch: { false }, record: { recorded += 1 })

        await progress.complete()

        XCTAssertEqual(recorded, 1)
        XCTAssertEqual(progress.isCompleted, true)
    }

    // verifies: ios-test-051, ios-rule-sources-03
    func testCompleteFailureIsStillCompleted() async {
        let progress = makeProgress(fetch: { false }, record: { throw Boom() })

        await progress.complete()

        XCTAssertEqual(progress.isCompleted, true)
    }

    // MARK: - 主体が変わった後の応答は書かない

    // verifies: ios-test-051, ios-contract-20.16
    func testRefreshSuspendedAcrossSubjectChangeDoesNotWrite() async {
        let rig = Rig()
        let task = Task { await rig.progress.refresh() }
        let suspended = await rig.fetch.waitUntilSuspended()
        XCTAssertTrue(suspended, "fetchStatus が呼ばれて保留される")
        XCTAssertEqual(rig.fetchCalls, 1)
        await rig.switchToBob()
        rig.fetch.resume(with: .success(false))
        await task.value

        XCTAssertNil(rig.progress.isCompleted, "前の主体の応答は B の状態を書き換えない")
        XCTAssertEqual(rig.sessionStore.token, "tB")
    }

    // verifies: ios-test-051, ios-contract-20.16
    func testCompleteSuspendedAcrossSubjectChangeDoesNotWrite() async {
        let rig = Rig()
        let task = Task { await rig.progress.complete() }
        let suspended = await rig.record.waitUntilSuspended()
        XCTAssertTrue(suspended, "recordCompleted が呼ばれて保留される")
        XCTAssertEqual(rig.recordCalls, 1)
        await rig.switchToBob()
        rig.record.resume(with: .success(()))
        await task.value

        XCTAssertNil(rig.progress.isCompleted, "前の主体の完了は B の状態を書き換えない")
        XCTAssertEqual(rig.sessionStore.token, "tB")
    }

    // verifies: ios-test-051
    func testRefreshFailureAfterSubjectChangeDoesNotWrite() async {
        let rig = Rig()
        let task = Task { await rig.progress.refresh() }
        let suspended = await rig.fetch.waitUntilSuspended()
        XCTAssertTrue(suspended)
        await rig.switchToBob()
        rig.fetch.resume(with: .failure(Boom()))
        await task.value

        XCTAssertNil(rig.progress.isCompleted, "失敗側（catch）も主体を照合する")
    }

    // verifies: ios-test-051
    func testRefreshAndCompleteWriteWhenSubjectIsUnchanged() async {
        let refreshRig = Rig()
        let refreshTask = Task { await refreshRig.progress.refresh() }
        let fetchSuspended = await refreshRig.fetch.waitUntilSuspended()
        XCTAssertTrue(fetchSuspended)
        refreshRig.fetch.resume(with: .success(false))
        await refreshTask.value
        XCTAssertEqual(refreshRig.progress.isCompleted, false, "正の対照: 主体が同じなら値が書かれる")

        let completeRig = Rig()
        let completeTask = Task { await completeRig.progress.complete() }
        let recordSuspended = await completeRig.record.waitUntilSuspended()
        XCTAssertTrue(recordSuspended)
        completeRig.record.resume(with: .success(()))
        await completeTask.value
        XCTAssertEqual(completeRig.progress.isCompleted, true, "正の対照: 主体が同じなら完了が書かれる")
    }

    // verifies: ios-test-051
    func testSuspendedHelperCompletesWhenResumedBeforeCalled() async {
        let rig = Rig()
        rig.fetch.resume(with: .success(true))
        rig.record.resume(with: .success(()))

        let refreshTask = Task { await rig.progress.refresh() }
        await refreshTask.value
        XCTAssertEqual(rig.progress.isCompleted, true, "再開が先でも結果が届く")

        let completeTask = Task { await rig.progress.complete() }
        await completeTask.value
        XCTAssertEqual(rig.progress.isCompleted, true)
    }

    // MARK: - adapter

    // verifies: ios-dec-103
    func testLiveWithoutClientLeavesRefreshNilAndCompleteTrue() async {
        let state = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(alice())
        let progress = OnboardingProgress.live(
            client: { nil },
            subjectStamp: { state.subjectStamp },
            isCurrentSubject: { _ in true }
        )

        await progress.refresh()
        XCTAssertNil(progress.isCompleted, "API 未設定の refresh は何も書かない")

        await progress.complete()
        XCTAssertEqual(progress.isCompleted, true, "API 未設定の complete は成功として完了")
    }
}
