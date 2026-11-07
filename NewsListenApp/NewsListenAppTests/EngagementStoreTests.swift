// verifies: ios-cmd-learning-01, ios-cmd-learning-05, ios-rule-learning-01, ios-rule-learning-02, ios-query-learning-02, ios-contract-20.16, ios-test-012, ios-test-029, ios-test-030
import XCTest
import os
@testable import NewsListenApp

/// `EngagementStore` のストリーク更新（ios-cmd-learning-05）、主体の照合（ios-contract-20.16）、
/// 実績の既読（ios-cmd-learning-01・ios-query-learning-02）、`PreferenceRegistry.seenAchievements`、
/// `LearningGateway.live(client:)` のテスト。
@MainActor
final class EngagementStoreTests: XCTestCase {

    // MARK: - fixtures

    private let alice = Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)
    private let bob = Subject(username: "bob", displayName: "Bob", role: Role(rawValue: "user"), key: nil)

    private func status(_ days: Int, today: Bool = true, last: String? = "2026-07-29") -> ListeningStreakStatus {
        ListeningStreakStatus(days: days, listenedToday: today, lastListenedDay: last)
    }

    private func streakJSON(days: Int, today: Bool = true, last: String = "2026-07-29") -> Data {
        Data(#"{"current_streak_days":\#(days),"today_listened":\#(today),"last_listened_day":"\#(last)"}"#.utf8)
    }

    private func summary(achievements: [Achievement] = []) -> LearningDashboardSummary {
        LearningDashboardSummary(
            streak: status(1),
            weekly: nil,
            weeklyHistory: [],
            achievements: achievements,
            monthlyListeningDays: [],
            completedCount: 0,
            masteredVocabularyCount: 0,
            currentLevel: "toeic_600",
            quizzedEpisodeCount: 0,
            averageCorrectRate: nil,
            quizTrend: []
        )
    }

    private func unlocked(_ ids: [String]) -> [Achievement] {
        ids.map { Achievement(id: $0, unlockedAt: "2026-07-29") }
    }

    /// 結果を呼出順に返す `fetchStreak`。順番が尽きたら最後の結果を返す。
    private final class StreakQueue: @unchecked Sendable {
        private let lock: OSAllocatedUnfairLock<[Result<ListeningStreakStatus, Error>]>

        init(_ results: [Result<ListeningStreakStatus, Error>]) {
            lock = OSAllocatedUnfairLock(initialState: results)
        }

        func next() throws -> ListeningStreakStatus {
            let result: Result<ListeningStreakStatus, Error> = lock.withLock { queue in
                queue.count > 1 ? queue.removeFirst() : queue[0]
            }
            return try result.get()
        }
    }

    /// 既読の保存先の記録 double（`seenStore` の 2 つの closure の組）。
    private final class SeenSpy: @unchecked Sendable {
        private struct State {
            var ids: Set<String>
            var writes: [Set<String>] = []
        }

        private let lock: OSAllocatedUnfairLock<State>

        init(_ ids: Set<String> = []) {
            lock = OSAllocatedUnfairLock(initialState: State(ids: ids))
        }

        var writes: [Set<String>] { lock.withLock { $0.writes } }

        var store: (read: () -> Set<String>, write: (Set<String>) -> Void) {
            (
                read: { [self] in lock.withLock { $0.ids } },
                write: { [self] newValue in lock.withLock { state in state.writes.append(newValue); state.ids = newValue } }
            )
        }
    }

    private func makeSignedInState() -> AppState {
        let state = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(LoginReceipt(token: "tA", subject: alice))
        return state
    }

    /// 主体の照合を常に通す store。`subjectStamp` は実物の `AppState` から取る（`SubjectStamp` はテストから作れない）。
    private func makeStore(gateway: LearningGateway, seen: SeenSpy = SeenSpy()) -> EngagementStore {
        let appState = makeSignedInState()
        return EngagementStore(
            gateway: gateway,
            seenStore: seen.store,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { _ in true }
        )
    }

    private func makeStore(streaks: [Result<ListeningStreakStatus, Error>]) -> EngagementStore {
        let double = RecordingLearningGateway()
        let queue = StreakQueue(streaks)
        double.fetchStreakImpl = { try queue.next() }
        return makeStore(gateway: double.gateway)
    }

    // MARK: - refreshStreak: 成功・404・失敗（CI-1〜CI-4、CI-22）

    // CI-1（T-S1。移設: testRefreshListeningStreakStoresSuccessfulResponse）
    func testRefreshStreakStoresSuccessfulResponse() async {
        let store = makeStore(streaks: [.success(status(0, today: false, last: "2026-07-03")), .success(status(3))])

        await store.refreshStreak()

        XCTAssertEqual(store.streak?.days, 0)
        XCTAssertEqual(store.streak?.lastListenedDay, "2026-07-03")
        XCTAssertEqual(store.streak?.isShown, false, "日数 0 は表示しない")
        XCTAssertFalse(store.streakLoadFailed)

        await store.refreshStreak()

        XCTAssertEqual(store.streak?.days, 3)
        XCTAssertEqual(store.streak?.isShown, true, "対照: 日数 3 は表示する")
    }

    // CI-2・CI-22（T-S2。移設: testRefreshListeningStreakTreats404AsUnavailableWithoutWarning）
    // verifies: ios-contract-19
    func testRefreshStreakTreats404AsUnavailableWithoutWarning() async {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 404))
        let store = makeStore(gateway: .live(apiClient: client))

        let receipt = await store.refreshStreak()

        XCTAssertNil(store.streak)
        XCTAssertFalse(store.streakLoadFailed)
        XCTAssertFalse(receipt.increased)
    }

    // CI-22（T-S2）: adapter は 404 の `.streak` を意味づけせずそのまま投げる。
    func testLiveFetchStreakKeepsNotFoundStreakFailure() async {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 404))
        let gateway = LearningGateway.live(apiClient: client)

        do {
            _ = try await gateway.fetchStreak()
            XCTFail("404 は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .notFound(subject: .streak))
        }
    }

    // CI-3（T-S3。移設: testRefreshListeningStreakClearsValueAndSurfacesNon404Failure）
    func testRefreshStreakClearsValueAndSurfacesNon404Failure() async {
        let store = makeStore(streaks: [.success(status(3)), .failure(ApiFailure.server(status: 500))])
        await store.refreshStreak()
        XCTAssertEqual(store.streak?.days, 3, "対照: 先に値がある")

        let receipt = await store.refreshStreak()

        XCTAssertNil(store.streak)
        XCTAssertTrue(store.streakLoadFailed)
        XCTAssertFalse(receipt.increased)
    }

    // CI-4（T-S4。移設: testRefreshListeningStreakPlaysStreakUpOnIncrease）
    func testRefreshStreakReportsIncreaseWhenDaysGrow() async {
        let store = makeStore(streaks: [.success(status(3, today: false, last: "2026-07-26")), .success(status(4))])
        await store.refreshStreak()

        let receipt = await store.refreshStreak()

        XCTAssertEqual(store.streak?.days, 4)
        XCTAssertTrue(receipt.increased)
    }

    // CI-4（T-S5。移設: testRefreshListeningStreakDoesNotPlayStreakUpOnInitialLoad）
    func testRefreshStreakDoesNotReportIncreaseOnInitialLoad() async {
        let store = makeStore(streaks: [.success(status(5))])

        let receipt = await store.refreshStreak()

        XCTAssertEqual(store.streak?.days, 5)
        XCTAssertFalse(receipt.increased)
    }

    // CI-4（T-S6。移設: testRefreshListeningStreakDoesNotPlayStreakUpWhenDecreaseOrSame）
    func testRefreshStreakDoesNotReportIncreaseWhenDecreaseOrSame() async {
        let decrease = makeStore(streaks: [.success(status(3, last: "2026-07-28")), .success(status(2, today: false, last: "2026-07-27"))])
        await decrease.refreshStreak()
        let decreaseReceipt = await decrease.refreshStreak()
        XCTAssertEqual(decrease.streak?.days, 2)
        XCTAssertFalse(decreaseReceipt.increased)

        let same = makeStore(streaks: [.success(status(3)), .success(status(3))])
        await same.refreshStreak()
        let sameReceipt = await same.refreshStreak()
        XCTAssertEqual(same.streak?.days, 3)
        XCTAssertFalse(sameReceipt.increased)
    }

    // CI-3・CI-4（T-S7）: 失敗や 404 の後の成功は、取得前が nil なので増加にしない。状態は遷移表どおり。
    func testRefreshStreakRecoversAfterFailureOr404WithoutReportingIncrease() async {
        let afterFailure = makeStore(streaks: [.success(status(2)), .failure(ApiFailure.server(status: 500)), .success(status(9))])
        await afterFailure.refreshStreak()
        await afterFailure.refreshStreak()
        XCTAssertNil(afterFailure.streak)
        XCTAssertTrue(afterFailure.streakLoadFailed)
        let recovered = await afterFailure.refreshStreak()
        XCTAssertEqual(afterFailure.streak?.days, 9)
        XCTAssertFalse(afterFailure.streakLoadFailed, "次の成功で警告が戻る")
        XCTAssertFalse(recovered.increased)

        let after404 = makeStore(streaks: [.success(status(2)), .failure(ApiFailure.notFound(subject: .streak)), .success(status(9))])
        await after404.refreshStreak()
        await after404.refreshStreak()
        XCTAssertNil(after404.streak)
        XCTAssertFalse(after404.streakLoadFailed, "404 は警告にしない")
        let recoveredFrom404 = await after404.refreshStreak()
        XCTAssertEqual(after404.streak?.days, 9)
        XCTAssertFalse(recoveredFrom404.increased)
    }

    // CI-5・CI-6（T-S8）: 同時の呼出は束ねない。各呼出は自分の取得前の値で判定し、応答の順に上書きする。
    func testConcurrentRefreshesJudgeEachAgainstItsOwnPreviousValueAndLastResponseWins() async {
        // (a) 取得前は days 2。2 つの呼出が同じ days 3 を受ける。
        let (storeA, holdsA) = makeHeldStore(initial: status(2), holds: 2)
        await storeA.refreshStreak()
        let firstA = Task { await storeA.refreshStreak() }
        await holdsA[0].waitUntilArrived()
        let secondA = Task { await storeA.refreshStreak() }
        await holdsA[1].waitUntilArrived()
        holdsA[0].complete(.success(status(3)))
        holdsA[1].complete(.success(status(3)))
        let receiptsA = [await firstA.value, await secondA.value]
        XCTAssertEqual(receiptsA.map(\.increased), [true, true], "どちらも取得前の 2 と比べる")
        XCTAssertEqual(storeA.streak?.days, 3)

        // (b) 後に始めた呼出の応答（days 3）が先に届き、先に始めた呼出の応答（days 5）が後に届く。
        let (storeB, holdsB) = makeHeldStore(initial: status(2), holds: 2)
        await storeB.refreshStreak()
        let firstB = Task { await storeB.refreshStreak() }
        await holdsB[0].waitUntilArrived()
        let secondB = Task { await storeB.refreshStreak() }
        await holdsB[1].waitUntilArrived()
        holdsB[1].complete(.success(status(3)))
        let secondReceipt = await secondB.value
        XCTAssertEqual(storeB.streak?.days, 3, "対照: 先に届いた応答がまず反映される")
        holdsB[0].complete(.success(status(5)))
        let firstReceipt = await firstB.value
        XCTAssertTrue(firstReceipt.increased)
        XCTAssertTrue(secondReceipt.increased)
        XCTAssertEqual(storeB.streak?.days, 5, "応答が届いた順に上書きする")
    }

    /// 1 回目は `initial` を即時に返し、2 回目以降は呼出ごとの `Hold` が解放するまで返らない `fetchStreak`。
    private func makeHeldStore(initial: ListeningStreakStatus, holds count: Int) -> (EngagementStore, [Hold<ListeningStreakStatus>]) {
        let holds = (0..<count).map { _ in Hold<ListeningStreakStatus>() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let double = RecordingLearningGateway()
        double.fetchStreakImpl = {
            let index = calls.withLock { value -> Int in defer { value += 1 }; return value }
            if index == 0 { return initial }
            return try await holds[index - 1].wait()
        }
        return (makeStore(gateway: double.gateway), holds)
    }

    // MARK: - 主体の照合（CI-5、CI-7）

    // CI-5（T-G1。移設: testTT14_19a_refreshListeningStreakGuardedBySubject）
    // verifies: ios-contract-20.16
    func testRefreshStreakResponseOfPreviousSubjectDoesNotWriteAfterSubjectSwitch() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/users/me/listening-streak")
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)
        appState.completeLogin(LoginReceipt(token: "tA", subject: alice))
        let engagement = EngagementStore(
            gateway: .live(client: { appState.apiClient }),
            seenStore: SeenSpy().store,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { appState.isCurrentSubject($0) }
        )
        XCTAssertNil(engagement.streak)
        XCTAssertFalse(engagement.streakLoadFailed)

        let task = Task { await engagement.refreshStreak() }
        await waitUntilStreakRequested(scripted)
        await appState.logout()
        appState.completeLogin(LoginReceipt(token: "tB", subject: bob))
        scripted.release(method: "GET", path: "/users/me/listening-streak", status: 200, body: streakJSON(days: 5))
        let receipt = await task.value

        XCTAssertNil(engagement.streak, "前の主体の応答は B の状態を書き換えない")
        XCTAssertFalse(engagement.streakLoadFailed)
        XCTAssertFalse(receipt.increased)
        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("B のまま") }
        XCTAssertEqual(store.token, "tB")
    }

    /// 保留した streak の GET が届くまで待つ。上限（約 5 秒）を超えたら `XCTFail` して戻る（届かなくてもテストを止めない）。
    private func waitUntilStreakRequested(_ scripted: ScriptedURLSession, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if scripted.sentRequests.contains(where: { $0.httpMethod == "GET" && $0.url?.path == "/users/me/listening-streak" }) {
                await scripted.waitUntilRequested(method: "GET", path: "/users/me/listening-streak")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("保留した GET /users/me/listening-streak が届かなかった", file: file, line: line)
    }

    /// 主体の照合を実物の `AppState` に任せた store と、2 回目の取得を保留できる gateway。
    private func makeGuardedStoreWithHeldSecondFetch() async -> (
        engagement: EngagementStore, appState: AppState, hold: Hold<ListeningStreakStatus>
    ) {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: InMemorySessionStore(token: "tA"))
        appState.completeLogin(LoginReceipt(token: "tA", subject: alice))
        let hold = Hold<ListeningStreakStatus>()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let double = RecordingLearningGateway()
        double.fetchStreakImpl = { [self] in
            let index = calls.withLock { value -> Int in defer { value += 1 }; return value }
            if index == 0 { return status(3) }
            return try await hold.wait()
        }
        let engagement = EngagementStore(
            gateway: double.gateway,
            seenStore: SeenSpy().store,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { appState.isCurrentSubject($0) }
        )
        await engagement.refreshStreak()
        return (engagement, appState, hold)
    }

    // CI-5（T-G2）: 404 の応答でも、主体が違えば何も書かない（A の値を消さない）。
    func testRefreshStreak404OfPreviousSubjectDoesNotClearValueAfterSubjectSwitch() async {
        let (engagement, appState, hold) = await makeGuardedStoreWithHeldSecondFetch()
        XCTAssertEqual(engagement.streak?.days, 3, "対照: A の値がある")

        let task = Task { await engagement.refreshStreak() }
        await hold.waitUntilArrived()
        await appState.logout()
        appState.completeLogin(LoginReceipt(token: "tB", subject: bob))
        hold.complete(.failure(ApiFailure.notFound(subject: .streak)))
        let receipt = await task.value

        XCTAssertEqual(engagement.streak?.days, 3)
        XCTAssertFalse(engagement.streakLoadFailed)
        XCTAssertFalse(receipt.increased)
    }

    // CI-5（T-G3）: その他の失敗でも、主体が違えば何も書かない（警告を立てない）。
    func testRefreshStreakFailureOfPreviousSubjectDoesNotWarnAfterSubjectSwitch() async {
        let (engagement, appState, hold) = await makeGuardedStoreWithHeldSecondFetch()

        let task = Task { await engagement.refreshStreak() }
        await hold.waitUntilArrived()
        await appState.logout()
        appState.completeLogin(LoginReceipt(token: "tB", subject: bob))
        hold.complete(.failure(ApiFailure.server(status: 500)))
        let receipt = await task.value

        XCTAssertEqual(engagement.streak?.days, 3)
        XCTAssertFalse(engagement.streakLoadFailed)
        XCTAssertFalse(receipt.increased)
    }

    // CI-5（T-G4）: stamp は取得の前に 1 回だけ捕捉し、照合は応答の後。
    func testRefreshStreakCapturesStampOnceBeforeFetchAndChecksSubjectAfterResponse() async {
        let appState = makeSignedInState()
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let double = RecordingLearningGateway()
        double.fetchStreakImpl = { [self] in
            log.withLock { $0.append("fetch") }
            return status(3)
        }
        let store = EngagementStore(
            gateway: double.gateway,
            seenStore: SeenSpy().store,
            subjectStamp: { log.withLock { $0.append("stamp") }; return appState.subjectStamp },
            isCurrentSubject: { _ in log.withLock { $0.append("check") }; return true }
        )

        await store.refreshStreak()

        XCTAssertEqual(log.withLock { $0 }, ["stamp", "fetch", "check"])
    }

    // CI-7（T-L1）: 主体の離脱では streak を消さない。次の主体の取得で置き換わる。
    func testStreakSurvivesLogoutAndIsReplacedByNextSubjectsFetch() async {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/users/me/listening-streak", status: 200, body: streakJSON(days: 4))
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: InMemorySessionStore(token: "tA"))
        appState.completeLogin(LoginReceipt(token: "tA", subject: alice))
        let engagement = EngagementStore(
            gateway: .live(client: { appState.apiClient }),
            seenStore: SeenSpy().store,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { appState.isCurrentSubject($0) }
        )
        await engagement.refreshStreak()
        XCTAssertEqual(engagement.streak?.days, 4)

        await appState.logout()
        XCTAssertEqual(engagement.streak?.days, 4, "離脱では消さない")

        appState.completeLogin(LoginReceipt(token: "tB", subject: bob))
        scripted.configure(method: "GET", path: "/users/me/listening-streak", status: 200, body: streakJSON(days: 1))
        await engagement.refreshStreak()
        XCTAssertEqual(engagement.streak?.days, 1, "B の取得で置き換わる")
    }

    // MARK: - 実績の既読（CI-12〜CI-14）

    // CI-12（T-U1。移設の一部: testAchievementTrackerReturnsOnlyUnseenUnlocksIncludingFirstLoad）
    // verifies: ios-test-029
    func testUnseenAchievementsReturnsAllInOrderOnFirstLoadAndNeverWrites() {
        let seen = SeenSpy()
        let store = makeStore(gateway: RecordingLearningGateway().gateway, seen: seen)
        let dashboard = summary(achievements: unlocked(["first_episode_completed", "streak_7"]))

        let first = store.unseenAchievements(in: dashboard)
        let second = store.unseenAchievements(in: dashboard)

        XCTAssertEqual(first.map(\.id), ["first_episode_completed", "streak_7"])
        XCTAssertEqual(second, first, "2 回呼んでも同じ")
        XCTAssertTrue(seen.writes.isEmpty, "読む操作は書かない")
    }

    // CI-12（T-U2）: 既読以外が返る。カタログに無い id も未表示になる。
    func testUnseenAchievementsExcludesSeenAndKeepsIdsOutsideCatalog() {
        let seen = SeenSpy(["streak_7"])
        let store = makeStore(gateway: RecordingLearningGateway().gateway, seen: seen)
        let dashboard = summary(achievements: unlocked(["streak_7", "future_unknown", "completed_10"]))

        let unseen = store.unseenAchievements(in: dashboard)

        XCTAssertEqual(unseen.map(\.id), ["future_unknown", "completed_10"])
        XCTAssertTrue(seen.writes.isEmpty)
        XCTAssertEqual(store.unseenAchievements(in: summary()), [], "対照: 実績が空なら空")
    }

    // CI-13（T-M1。移設の残り: testAchievementTrackerReturnsOnlyUnseenUnlocksIncludingFirstLoad）
    // verifies: ios-test-012
    func testMarkAchievementsSeenThenOnlyNewUnlockIsUnseen() {
        let store = makeStore(gateway: RecordingLearningGateway().gateway, seen: SeenSpy())
        let firstIds = ["first_episode_completed", "streak_7"]
        let first = store.unseenAchievements(in: summary(achievements: unlocked(firstIds)))
        store.markAchievementsSeen(first.map(\.id))

        let second = store.unseenAchievements(in: summary(achievements: unlocked(firstIds + ["completed_10"])))

        XCTAssertEqual(first.map(\.id), firstIds)
        XCTAssertEqual(second.map(\.id), ["completed_10"])
    }

    // CI-13（T-M2）: 空なら write を呼ばない。
    func testMarkAchievementsSeenWithEmptyIdsDoesNotWrite() {
        let seen = SeenSpy()
        let store = makeStore(gateway: RecordingLearningGateway().gateway, seen: seen)

        store.markAchievementsSeen([])
        XCTAssertTrue(seen.writes.isEmpty)

        store.markAchievementsSeen(["a"])
        XCTAssertEqual(seen.writes.count, 1, "対照: 空でなければ書く")
    }

    // CI-13（T-M3）: 空でなければ read().union(ids) を書く。同じ id の再度の呼出は集合を変えない。
    func testMarkAchievementsSeenSavesUnionSortedAndIsIdempotent() {
        let suiteName = "EngagementStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = PreferenceRegistry(defaults: defaults)
        registry.seenAchievements.write(["b"])
        let appState = makeSignedInState()
        let registryStore = EngagementStore(
            gateway: RecordingLearningGateway().gateway,
            seenStore: registry.seenAchievements,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { _ in true }
        )

        registryStore.markAchievementsSeen(["a"])
        XCTAssertEqual(defaults.stringArray(forKey: "seen_achievement_ids"), ["a", "b"])

        registryStore.markAchievementsSeen(["a"])
        XCTAssertEqual(defaults.stringArray(forKey: "seen_achievement_ids"), ["a", "b"], "2 回目で集合は変わらない")
    }

    // CI-14・CI-24（T-M4）: 集合を保持しない。離脱で消えた値を復活させない。
    func testMarkAchievementsSeenDoesNotRetainSetAcrossSubjectClear() {
        let suiteName = "EngagementStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = PreferenceRegistry(defaults: defaults)
        let appState = makeSignedInState()
        let store = EngagementStore(
            gateway: RecordingLearningGateway().gateway,
            seenStore: registry.seenAchievements,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { _ in true }
        )
        let dashboard = summary(achievements: unlocked(["a", "b"]))
        store.markAchievementsSeen(["a", "b"])
        XCTAssertEqual(store.unseenAchievements(in: dashboard), [], "対照: 記録した後は出ない")

        registry.clearSubjectScoped()

        XCTAssertEqual(store.unseenAchievements(in: dashboard).map(\.id), ["a", "b"], "離脱で消えた分は未表示に戻る")
        store.markAchievementsSeen(["c"])
        XCTAssertEqual(defaults.stringArray(forKey: "seen_achievement_ids"), ["c"], "消えた id が復活しない")
    }

    // MARK: - PreferenceRegistry.seenAchievements（CI-24）

    // CI-24（T-R1）: key は `seen_achievement_ids`。write は `sorted()` の配列。型の不一致は空。
    func testRegistrySeenAchievementsRoundTripsSortedUnderTheSameKeyAndFallsBackToEmpty() {
        let suiteName = "EngagementStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = PreferenceRegistry(defaults: defaults)
        XCTAssertEqual(registry.seenAchievements.read(), [], "未保存は空")

        let ids = Set((0..<20).map { "achievement_\($0 * 7 % 20)" })
        registry.seenAchievements.write(ids)

        XCTAssertEqual(defaults.stringArray(forKey: "seen_achievement_ids"), ids.sorted(), "sorted() の配列で書く")
        XCTAssertEqual(registry.seenAchievements.read(), ids)

        defaults.set(["x"], forKey: "seen_achievement_ids")
        XCTAssertEqual(registry.seenAchievements.read(), ["x"], "key に入れた値を呼出のたびに読む")

        defaults.set("not-an-array", forKey: "seen_achievement_ids")
        XCTAssertEqual(registry.seenAchievements.read(), [], "型の不一致は空")
        defaults.set([1, 2], forKey: "seen_achievement_ids")
        XCTAssertEqual(registry.seenAchievements.read(), [], "要素の型の不一致は空")
    }

    // MARK: - LearningGateway.live(client:)（CI-20、CI-21）

    // CI-21（T-A1）: client が nil なら全 7 closure が `ApiFailure.network` を投げ、`refreshStreak()` は (nil, true)。
    func testLiveWithoutClientThrowsNetworkFailureFromEveryClosureAndStoreWarns() async {
        let gateway = LearningGateway.live(client: { nil })
        let expected = ApiFailure.network(URLError(.badURL))

        func assertNetwork(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail("\(name) は投げる")
            } catch {
                XCTAssertEqual(error as? ApiFailure, expected, name)
            }
        }
        await assertNetwork("fetchVocabulary") { _ = try await gateway.fetchVocabulary() }
        await assertNetwork("saveVocabulary") { try await gateway.saveVocabulary("e1", "term") }
        await assertNetwork("fetchTestSession") { _ = try await gateway.fetchTestSession() }
        await assertNetwork("submitTestResult") { try await gateway.submitTestResult(VocabularyTest()) }
        await assertNetwork("submitQuiz") { _ = try await gateway.submitQuiz("e1", [0]) }
        await assertNetwork("fetchDashboard") { _ = try await gateway.fetchDashboard() }
        await assertNetwork("fetchStreak") { _ = try await gateway.fetchStreak() }

        let store = makeStore(gateway: gateway)
        let receipt = await store.refreshStreak()
        XCTAssertNil(store.streak)
        XCTAssertTrue(store.streakLoadFailed)
        XCTAssertFalse(receipt.increased)
    }

    // CI-20（T-A2）: 呼出のたびに client を解決する（1 回だけ解決して持ち越さない）。
    func testLiveResolvesClientOnEveryCall() async throws {
        let sessionA = MockURLSession(data: streakJSON(days: 1), statusCode: 200)
        let sessionB = MockURLSession(data: streakJSON(days: 2), statusCode: 200)
        let clientA = APIClient(baseURL: URL(string: "https://a.example.com")!, apiKey: "key", session: sessionA)
        let clientB = APIClient(baseURL: URL(string: "https://b.example.com")!, apiKey: "key", session: sessionB)
        let current = OSAllocatedUnfairLock<APIClient>(initialState: clientA)
        let gateway = LearningGateway.live(client: { current.withLock { $0 } })

        let first = try await gateway.fetchStreak()
        current.withLock { $0 = clientB }
        let second = try await gateway.fetchStreak()

        XCTAssertEqual(first.days, 1)
        XCTAssertEqual(second.days, 2)
        XCTAssertEqual(sessionA.lastRequest?.url?.host, "a.example.com")
        XCTAssertEqual(sessionB.lastRequest?.url?.host, "b.example.com", "2 回目は差し替えた client に届く")
    }
}
