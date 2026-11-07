// verifies: T-LearningViewModel-order
import XCTest
import os
@testable import NewsListenApp

/// `LearningViewModel.load()` の現行の挙動を固定する特性テスト（ios-slice-learning-03）。
///
/// Then（このファイルの `// MARK: - Given` より上）は付け替えの前後で変えない。
/// 付け替えで書き換えてよいのは `// MARK: - Given` 以下だけで、本体は次の 8 個の helper だけを使う:
/// `makeViewModel`・`dashboardCompletedCount(of:)`・`seenIds()`・`seenWriteCount()`・`fetchLog()`・
/// `seenIdsAtVocabularyFetch()`・`holdDashboard()`・`releaseDashboard(_:)`。
@MainActor
final class LearningViewModelTests: XCTestCase {

    fileprivate var given: LearningVMGiven!

    // MARK: - load() の呼出順と既読（CI-15）

    // CI-15（T-V1）: ダッシュボード → 語彙 → 出題。既読の記録は語彙の取得より前。
    func testLoadFetchesDashboardThenVocabularyThenTestSessionAndRecordsSeenBeforeVocabulary() async {
        let viewModel = makeViewModel(script: [LoadScript(unlocked: ["a", "b"])])

        await viewModel.load()

        XCTAssertEqual(fetchLog(), ["dashboard", "vocabulary", "test-session"])
        XCTAssertEqual(seenIdsAtVocabularyFetch(), ["a", "b"], "語彙を取得する時点で、解錠済みの全 id が既読になっている")
    }

    // CI-15（T-V2）: 既読は解錠済みの全 id の union。通知するのは未表示だけ。
    func testLoadWithNewUnlockNotifiesOnlyUnseenAndSavesUnionOfAllUnlockedIds() async {
        let viewModel = makeViewModel(seen: ["a"], script: [LoadScript(unlocked: ["a", "b"])])

        await viewModel.load()

        XCTAssertEqual(viewModel.newlyUnlocked.map(\.id), ["b"])
        XCTAssertEqual(seenIds(), ["a", "b"])
        XCTAssertEqual(seenWriteCount(), 1, "正方向の対照: 新しい解錠があるときは 1 回書く")
    }

    // CI-15（T-V3 a）: 解錠がすべて既読なら書かない。
    func testLoadWithOnlySeenUnlocksDoesNotWrite() async {
        let viewModel = makeViewModel(seen: ["a"], script: [LoadScript(unlocked: ["a"])])

        await viewModel.load()

        XCTAssertEqual(seenWriteCount(), 0)
        XCTAssertEqual(seenIds(), ["a"])
        XCTAssertTrue(viewModel.newlyUnlocked.isEmpty)
    }

    // CI-15（T-V3 b）: 解錠が無ければ書かない（既読の中身も変わらない）。
    func testLoadWithoutUnlocksDoesNotWrite() async {
        let viewModel = makeViewModel(seen: ["z"], script: [LoadScript(unlocked: [])])

        await viewModel.load()

        XCTAssertEqual(seenWriteCount(), 0)
        XCTAssertEqual(seenIds(), ["z"])
        XCTAssertTrue(viewModel.newlyUnlocked.isEmpty)
    }

    // CI-15（T-V3 c）: 2 回目の load() は既読済みなので書かず、newlyUnlocked は 1 回目のまま。
    func testSecondLoadWithAlreadyRecordedUnlockDoesNotWriteAndKeepsNewlyUnlocked() async {
        let viewModel = makeViewModel(script: [LoadScript(unlocked: ["b"]), LoadScript(unlocked: ["b"])])

        await viewModel.load()
        XCTAssertEqual(viewModel.newlyUnlocked.map(\.id), ["b"], "対照: 1 回目で新しい解錠が通知される")
        let before = seenWriteCount()
        XCTAssertEqual(before, 1)

        await viewModel.load()

        XCTAssertEqual(seenWriteCount(), before, "2 回目は増分 0")
        XCTAssertEqual(viewModel.newlyUnlocked.map(\.id), ["b"])
    }

    // MARK: - 取得失敗（CI-16、CI-17）

    // CI-16（T-V4）: ダッシュボードの失敗で表示済みを残し、語彙と出題は試み、次の成功で loadFailed が戻る。
    func testDashboardFailureKeepsShownDataStillFetchesVocabularyAndRecoversOnNextSuccess() async {
        let viewModel = makeViewModel(script: [
            LoadScript(dashboardCompleted: 3),
            .dashboardFailure,
            LoadScript(dashboardCompleted: 5),
        ])

        await viewModel.load()
        XCTAssertEqual(dashboardCompletedCount(of: viewModel), 3)
        XCTAssertFalse(viewModel.loadFailed)
        let writesBefore = seenWriteCount()
        let logBefore = fetchLog().count

        await viewModel.load()

        XCTAssertEqual(dashboardCompletedCount(of: viewModel), 3, "表示済みを消さない")
        XCTAssertTrue(viewModel.loadFailed)
        XCTAssertEqual(Array(fetchLog().dropFirst(logBefore)), ["dashboard", "vocabulary", "test-session"], "失敗しても語彙と出題は試みる")
        XCTAssertEqual(seenWriteCount(), writesBefore)

        await viewModel.load()

        XCTAssertFalse(viewModel.loadFailed)
        XCTAssertEqual(dashboardCompletedCount(of: viewModel), 5)
    }

    // CI-16（T-V4 初回）: 初回の失敗は dashboard が nil のまま loadFailed。
    func testFirstDashboardFailureLeavesDashboardNilAndMarksLoadFailed() async {
        let viewModel = makeViewModel(script: [.dashboardFailure])

        await viewModel.load()

        XCTAssertNil(dashboardCompletedCount(of: viewModel))
        XCTAssertTrue(viewModel.loadFailed)
        XCTAssertEqual(fetchLog(), ["dashboard", "vocabulary", "test-session"])
    }

    // CI-17（T-V5）: 語彙・出題の失敗は best-effort。表示済みを残し、loadFailed にしない。
    func testVocabularyAndTestSessionFailuresKeepShownValuesAndDoNotFailLoad() async {
        let viewModel = makeViewModel(script: [
            LoadScript(vocabularyCount: 7, dueWords: 2),
            LoadScript(vocabularyCount: nil, dueWords: nil),
        ])

        await viewModel.load()
        XCTAssertEqual(viewModel.vocabulary?.count, 7)
        XCTAssertEqual(viewModel.dueVocabularyCount, 2)

        await viewModel.load()

        XCTAssertEqual(viewModel.vocabulary?.count, 7)
        XCTAssertEqual(viewModel.dueVocabularyCount, 2)
        XCTAssertFalse(viewModel.loadFailed)
    }

    // MARK: - isLoading と祝いを閉じる（CI-18、CI-19）

    // CI-18（T-V6）: isLoading はダッシュボードが nil のときだけ読み込み中に真。
    func testIsLoadingIsTrueOnlyWhileDashboardIsNilAndLoading() async {
        let viewModel = makeViewModel(script: [LoadScript(dashboardCompleted: 1), LoadScript(dashboardCompleted: 2)])
        let first = holdDashboard()
        let second = holdDashboard()

        let task1 = Task { await viewModel.load() }
        await first.waitUntilArrived()
        XCTAssertTrue(viewModel.isLoading, "初回の保留中は読み込み中")
        releaseDashboard(first)
        await task1.value
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(dashboardCompletedCount(of: viewModel), 1)

        let task2 = Task { await viewModel.load() }
        await second.waitUntilArrived()
        XCTAssertFalse(viewModel.isLoading, "値がある 2 回目の保留中は読み込み中にしない")
        releaseDashboard(second)
        await task2.value
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(dashboardCompletedCount(of: viewModel), 2)
    }

    // CI-19（T-V7）: 閉じると空になり、既読のままなので次の load() でも再表示しない。
    func testDismissClearsNewlyUnlockedAndNextLoadDoesNotShowItAgain() async {
        let viewModel = makeViewModel(script: [LoadScript(unlocked: ["a"]), LoadScript(unlocked: ["a"])])
        await viewModel.load()
        XCTAssertEqual(viewModel.newlyUnlocked.map(\.id), ["a"], "対照: 新しい解錠が通知される")

        viewModel.dismissAchievementCelebration()
        XCTAssertTrue(viewModel.newlyUnlocked.isEmpty)

        await viewModel.load()

        XCTAssertTrue(viewModel.newlyUnlocked.isEmpty)
    }

}

// MARK: - Given
// 以下だけを付け替えで書き換える（Then は変えない）。

/// 1 回の `load()` ぶんの応答の台本。`nil` はその取得の失敗。
struct LoadScript {
    var dashboardCompleted: Int? = 3
    var unlocked: [String] = []
    var vocabularyCount: Int? = 7
    var dueWords: Int? = 2

    static let dashboardFailure = LoadScript(dashboardCompleted: nil)
}

extension LearningViewModelTests {
    fileprivate func makeViewModel(seen: Set<String> = [], script: [LoadScript]) -> LearningViewModel {
        let environment = LearningVMGiven(seen: seen, script: script)
        given = environment
        return environment.viewModel
    }

    fileprivate func dashboardCompletedCount(of viewModel: LearningViewModel) -> Int? {
        viewModel.dashboard?.completedCount
    }

    fileprivate func seenIds() -> Set<String> {
        Set(given.defaults.stringArray(forKey: PreferenceRegistry.seenAchievementIdsKey) ?? [])
    }

    fileprivate func seenWriteCount() -> Int {
        given.defaults.writeCount
    }

    fileprivate func fetchLog() -> [String] {
        given.recorder.log
    }

    fileprivate func seenIdsAtVocabularyFetch() -> Set<String>? {
        given.recorder.seenAtLastVocabularyFetch
    }

    fileprivate func holdDashboard() -> Hold<Void> {
        let hold = Hold<Void>()
        given.recorder.enqueueHold(hold)
        return hold
    }

    fileprivate func releaseDashboard(_ hold: Hold<Void>) {
        hold.complete(.success(()))
    }
}

/// 取得の順と、語彙の取得時点の既読を記録する。ダッシュボードの取得は保留できる。
final class LoadRecorder: @unchecked Sendable {
    private struct State {
        var dashboardCalls = 0
        var vocabularyCalls = 0
        var testSessionCalls = 0
        var log: [String] = []
        var holds: [Hold<Void>] = []
        var seenAtLastVocabularyFetch: Set<String>?
    }

    private let script: [LoadScript]
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(script: [LoadScript]) {
        self.script = script
    }

    var log: [String] { lock.withLock { $0.log } }
    var seenAtLastVocabularyFetch: Set<String>? { lock.withLock { $0.seenAtLastVocabularyFetch } }

    func enqueueHold(_ hold: Hold<Void>) {
        lock.withLock { $0.holds.append(hold) }
    }

    private func entry(_ index: Int) -> LoadScript {
        script[min(index, script.count - 1)]
    }

    func dashboard() async throws -> LearningDashboardSummary {
        let (index, hold) = lock.withLock { state -> (Int, Hold<Void>?) in
            state.log.append("dashboard")
            defer { state.dashboardCalls += 1 }
            return (state.dashboardCalls, state.holds.isEmpty ? nil : state.holds.removeFirst())
        }
        if let hold { try await hold.wait() }
        let current = entry(index)
        guard let completed = current.dashboardCompleted else { throw ApiFailure.server(status: 500) }
        return LearningDashboardSummary(
            streak: ListeningStreakStatus(days: 1, listenedToday: false, lastListenedDay: "2026-07-01"),
            weekly: nil, weeklyHistory: [],
            achievements: current.unlocked.map { Achievement(id: $0, unlockedAt: "2026-07-29") },
            monthlyListeningDays: [], completedCount: completed, masteredVocabularyCount: 0,
            currentLevel: "toeic_600", quizzedEpisodeCount: 0, averageCorrectRate: nil, quizTrend: [])
    }

    func vocabulary(seen: Set<String>) async throws -> (terms: [SavedTerm], count: Int) {
        let index = lock.withLock { state -> Int in
            state.log.append("vocabulary")
            state.seenAtLastVocabularyFetch = seen
            defer { state.vocabularyCalls += 1 }
            return state.vocabularyCalls
        }
        guard let count = entry(index).vocabularyCount else { throw ApiFailure.server(status: 500) }
        let terms = (0..<count).map {
            SavedTerm(episodeId: "e1", term: "term\($0)", meaning: "意味\($0)", registeredAt: "2026-11-07T00:00:00Z")
        }
        return (terms: terms, count: count)
    }

    func testSession() async throws -> [VocabularyTestWord] {
        let index = lock.withLock { state -> Int in
            state.log.append("test-session")
            defer { state.testSessionCalls += 1 }
            return state.testSessionCalls
        }
        guard let words = entry(index).dueWords else { throw ApiFailure.server(status: 500) }
        return (0..<words).map { LearningFixture.word("w\($0)") }
    }
}

/// 付け替え後の Given: 記録する gateway の double と、実物の `EngagementStore`・`VocabularyBook`・`VocabularyTesting`。
@MainActor
final class LearningVMGiven {
    let suiteName = "LearningViewModelTests.\(UUID().uuidString)"
    let defaults: RecordingUserDefaults
    let recorder: LoadRecorder
    let viewModel: LearningViewModel

    init(seen: Set<String>, script: [LoadScript]) {
        let defaults = RecordingUserDefaults(suiteName: suiteName)!
        self.defaults = defaults
        let registry = PreferenceRegistry(defaults: defaults)
        if !seen.isEmpty {
            registry.seenAchievements.write(seen)
        }
        defaults.resetCounts()
        let recorder = LoadRecorder(script: script)
        self.recorder = recorder
        let double = RecordingLearningGateway()
        double.fetchDashboardImpl = { try await recorder.dashboard() }
        double.fetchVocabularyImpl = { try await recorder.vocabulary(seen: registry.seenAchievements.read()) }
        double.fetchTestSessionImpl = { try await recorder.testSession() }
        let appState = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        let engagement = EngagementStore(
            gateway: double.gateway,
            seenStore: registry.seenAchievements,
            subjectStamp: { appState.subjectStamp },
            isCurrentSubject: { _ in true }
        )
        viewModel = LearningViewModel(
            engagement: engagement,
            vocabularyBook: VocabularyBook(gateway: double.gateway),
            vocabularyTesting: VocabularyTesting(gateway: double.gateway)
        )
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
