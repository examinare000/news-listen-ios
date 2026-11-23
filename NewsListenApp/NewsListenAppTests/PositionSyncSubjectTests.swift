import XCTest
@testable import NewsListenApp

/// 位置の記録と主体離脱・起動時の回収（`AppState` + 実 `PositionRecords` + `InMemoryPositionStore`）。
///
/// 合成 root と同じ配線（束縛・離脱の削除・回収）を `Harness` で再現し、実 `PositionReporter` の再送で「送られたか」を見る。
@MainActor
final class PositionSyncSubjectTests: XCTestCase {

    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func subject(_ username: String, key: SubjectKey?) -> Subject {
        Subject(username: username, displayName: username, role: Role(rawValue: "user"), key: key)
    }

    private func meJSON(userId: String?) -> Data {
        let idPart = userId.map { #","user_id":"\#($0)""# } ?? ""
        return Data(#"{"username":"alice","role":"user","display_name":"alice"\#(idPart)}"#.utf8)
    }

    private func unsentRecord(_ subject: SubjectKey, _ id: String, _ seconds: Double = 10) -> PositionRecord {
        PositionRecord(subject: subject, episodeId: id, seconds: seconds, recordedAt: recordedAt, isSent: false)
    }

    /// 合成 root と同じ形で `AppState` と `PositionRecords` を結ぶ。
    @MainActor
    private final class Harness {
        let store = InMemoryPositionStore()
        let records: PositionRecords
        let gateway = RecordingPlaybackGateway(response: { EntryFixture.playable($0) })
        let reporter: PositionReporter
        let state: AppState
        let offlineReclaims = Counter()
        let offlineClears = Counter()
        let positionReclaims = Counter()
        let positionClears = Counter()

        @MainActor
        final class Counter {
            private(set) var calls: [SubjectKey?] = []
            func record(_ key: SubjectKey?) { calls.append(key) }
        }

        init(
            session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200),
            token: String? = nil,
            seed: [(SubjectKey, [PositionRecord])] = [],
            offlineClearError: Error? = nil,
            offlineReclaimError: Error? = nil,
            positionClearError: Error? = nil,
            positionReclaimError: Error? = nil
        ) {
            for (key, records) in seed { store.seed(records, for: key) }
            let records = PositionRecords(store: store.store)
            self.records = records
            reporter = PositionReporter(
                updatePosition: gateway.updatePosition,
                markCompleted: gateway.markCompleted,
                onPositionSaved: { _ in },
                onCompletionRecorded: {},
                beginBackgroundTask: { {} },
                records: records,
                connectivity: makeSilentConnectivity())
            let offlineClears = self.offlineClears
            let offlineReclaims = self.offlineReclaims
            let positionClears = self.positionClears
            let positionReclaims = self.positionReclaims
            state = AppState(
                sessionStore: InMemorySessionStore(token: token),
                accountGatewayFactory: { token, onUnauthorized in
                    AccountGateway.live(apiClient: APIClient(
                        baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token,
                        session: session, onUnauthorized: onUnauthorized))
                },
                nowPlayingCenter: NowPlayingCenterSpy(),
                clearOfflineLibrary: { key in
                    offlineClears.record(key)
                    if let offlineClearError { throw offlineClearError }
                },
                bindOfflineSubject: { key in records.bind(subject: key) },
                reclaimOfflineLibrary: { key in
                    offlineReclaims.record(key)
                    if let offlineReclaimError { throw offlineReclaimError }
                },
                clearPositionRecords: { key in
                    positionClears.record(key)
                    if let positionClearError { throw positionClearError }
                    if let key { try records.remove(subject: key) }
                },
                reclaimPositionRecords: { key in
                    positionReclaims.record(key)
                    if let positionReclaimError { throw positionReclaimError }
                    try records.reclaim(keeping: key)
                })
        }

        /// 再送を起こし、静止するまで待つ。送られた件数（gateway の書込）を返す。
        func resendAndCountSends() async -> Int {
            reporter.resendUnsent()
            for _ in 0..<25 {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return gateway.writeCount
        }
    }

    private struct Failure: Error {}

    private func login(_ harness: Harness, as key: SubjectKey, token: String = "tA") {
        harness.state.completeLogin(LoginReceipt(token: token, subject: subject("alice", key: key)))
    }

    // MARK: - 離脱

    // verifies: ios-dec-134, shared-leave-11
    // kills: logout で未送信を送る／離脱主体の記録が残る／logout しなくても送られない（対照）
    func testLogoutDeletesUnsentWithoutSending() async throws {
        let harness = Harness()
        login(harness, as: subjectA)
        harness.records.record(episodeId: "e", seconds: 10, at: recordedAt)
        XCTAssertEqual(harness.store.stored(for: subjectA).count, 1, "Given: 未送信の記録がある")

        await harness.state.logout()
        let sentAfterLogout = await harness.resendAndCountSends()

        XCTAssertEqual(sentAfterLogout, 0, "離脱の後に送らない")
        XCTAssertTrue(harness.store.stored(for: subjectA).isEmpty, "離脱主体の記録は store から消える")
        XCTAssertTrue(harness.records.unsent().isEmpty)
        XCTAssertNil(harness.state.lastCleanupIncomplete)

        // 対照: logout しなければ再送で送られる。
        let control = Harness()
        login(control, as: subjectA)
        control.records.record(episodeId: "e", seconds: 10, at: recordedAt)
        let sentWithoutLogout = await control.resendAndCountSends()
        XCTAssertEqual(sentWithoutLogout, 1)
    }

    // verifies: ios-dec-134, shared-leave-04
    // kills: 位置の記録の消去の失敗を黙殺する
    func testPositionRecordsCleanupFailureIsReportedAsPositionRecordsPart() async throws {
        let harness = Harness(positionClearError: Failure())
        login(harness, as: subjectA)

        await harness.state.logout()

        XCTAssertEqual(harness.state.lastCleanupIncomplete?.failedParts, [.positionRecords])
    }

    // verifies: ios-dec-134
    // kills: 片方の手順の失敗でもう片方を止める／失敗部位を片方だけ載せる
    func testCleanupStepsAreIndependent() async throws {
        let positionsFail = Harness(positionClearError: Failure())
        login(positionsFail, as: subjectA)
        await positionsFail.state.logout()
        XCTAssertEqual(positionsFail.offlineClears.calls, [subjectA], "位置が失敗しても音声は消す")
        XCTAssertEqual(positionsFail.state.lastCleanupIncomplete?.failedParts, [.positionRecords])

        let offlineFails = Harness(offlineClearError: Failure())
        login(offlineFails, as: subjectA)
        offlineFails.records.record(episodeId: "e", seconds: 10, at: recordedAt)
        await offlineFails.state.logout()
        XCTAssertEqual(offlineFails.positionClears.calls, [subjectA], "音声が失敗しても位置は消す")
        XCTAssertTrue(offlineFails.store.stored(for: subjectA).isEmpty)
        XCTAssertEqual(offlineFails.state.lastCleanupIncomplete?.failedParts, [.offlineLibrary])

        let bothFail = Harness(offlineClearError: Failure(), positionClearError: Failure())
        login(bothFail, as: subjectA)
        await bothFail.state.logout()
        XCTAssertEqual(bothFail.state.lastCleanupIncomplete?.failedParts, [.offlineLibrary, .positionRecords])
    }

    // verifies: ios-dec-134, shared-leave-02
    // kills: 失効（401）の離脱で記録が残る・送られる
    func testUnauthorizedDeletesUnsentWithoutSending() async throws {
        let harness = Harness()
        login(harness, as: subjectA)
        harness.records.record(episodeId: "e", seconds: 10, at: recordedAt)

        harness.state.handle(failure: .unauthorized, sentToken: "tA")
        let sent = await harness.resendAndCountSends()

        XCTAssertEqual(sent, 0)
        XCTAssertTrue(harness.store.stored(for: subjectA).isEmpty)
        XCTAssertTrue(harness.records.unsent().isEmpty)
    }

    // verifies: ios-dec-134, shared-leave-07
    // kills: 直接交代で前の主体の記録が残る／新しい主体へ束縛しない
    func testDirectSwapDeletesDepartingSubjectsRecords() async throws {
        let harness = Harness()
        login(harness, as: subjectA)
        harness.records.record(episodeId: "e", seconds: 10, at: recordedAt)

        harness.state.completeLogin(LoginReceipt(token: "tB", subject: subject("bob", key: subjectB)))

        XCTAssertTrue(harness.store.stored(for: subjectA).isEmpty, "A の記録が消える")
        XCTAssertTrue(harness.records.unsent().isEmpty, "B からは何も見えない")
        harness.records.record(episodeId: "f", seconds: 5, at: recordedAt)
        XCTAssertEqual(harness.store.stored(for: subjectB).map(\.episodeId), ["f"], "B に束縛されている")
    }

    // MARK: - 起動時の回収

    // verifies: ios-dec-134, shared-leave-08
    // kills: 位置の回収の失敗を黙殺する／位置の失敗で音声の回収を止める
    func testStartupReclaimFailureOfPositionRecordsIsReportedAndOfflineLibraryStillRuns() async throws {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let harness = Harness(session: scripted, token: "tA", positionReclaimError: Failure())

        await harness.state.resolve()

        XCTAssertEqual(harness.state.lastCleanupIncomplete?.failedParts, [.positionRecords])
        XCTAssertEqual(harness.offlineReclaims.calls, [subjectA], "音声の回収は走る")
    }

    // verifies: ios-dec-134
    // kills: 後勝ちで失敗部位を上書きする
    func testStartupReclaimBothFailuresAreReportedTogether() async throws {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let harness = Harness(
            session: scripted, token: "tA", offlineReclaimError: Failure(), positionReclaimError: Failure())

        await harness.state.resolve()

        XCTAssertEqual(harness.state.lastCleanupIncomplete?.failedParts, [.offlineLibrary, .positionRecords])
    }

    // verifies: ios-dec-134, shared-leave-12
    // kills: 別主体の未送信が残る・現在の主体のトークンで送られる／現在の主体の記録まで消す
    func testStartupReclaimDeletesOtherSubjectsRecords() async throws {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let harness = Harness(
            session: scripted, token: "tA",
            seed: [(subjectA, [unsentRecord(subjectA, "ea")]), (subjectB, [unsentRecord(subjectB, "eb")])])

        await harness.state.resolve()
        let sent = await harness.resendAndCountSends()

        XCTAssertEqual(harness.store.subjectNames, [subjectA.rawValue], "B の記録は消え、A の記録は残る")
        XCTAssertEqual(sent, 1, "A の記録だけが送られる")
        XCTAssertTrue(harness.records.unsent().isEmpty, "A の分は送信済みになった")
    }

    // verifies: ios-dec-134
    // kills: 未認証（トークン無し・401）で記録が残る
    func testStartupReclaimWithAnonymousDeletesAll() async throws {
        let seed: [(SubjectKey, [PositionRecord])] = [
            (subjectA, [unsentRecord(subjectA, "ea")]), (subjectB, [unsentRecord(subjectB, "eb")]),
        ]
        let noToken = Harness(seed: seed)
        await noToken.state.resolve()
        XCTAssertTrue(noToken.store.subjectNames.isEmpty, "トークン無し")

        let unauthorized = Harness(
            session: MockURLSession(data: Data(), statusCode: 401), token: "tA", seed: seed)
        await unauthorized.state.resolve()
        XCTAssertTrue(unauthorized.store.subjectNames.isEmpty, "401")
    }

    // verifies: ios-dec-134, shared-leave-13, shared-sync-02
    // kills: unavailable の間に回収する・記録する／対照（認証が確定すれば記録できる）
    func testUnavailableDoesNotReclaimOrResend() async throws {
        let seed: [(SubjectKey, [PositionRecord])] = [(subjectA, [unsentRecord(subjectA, "ea")])]
        let unavailable = Harness(
            session: MockURLSession(mode: .transportError(URLError(.notConnectedToInternet))),
            token: "tA", seed: seed)
        await unavailable.state.resolve()
        guard case .unavailable = unavailable.state.session else { return XCTFail("unavailable になるべき") }

        XCTAssertEqual(unavailable.store.reclaimCount, 0)
        XCTAssertNil(unavailable.records.record(episodeId: "f", seconds: 1, at: recordedAt))
        XCTAssertEqual(unavailable.store.writeCount, 0)
        XCTAssertTrue(unavailable.records.unsent().isEmpty)
        let sent = await unavailable.resendAndCountSends()
        XCTAssertEqual(sent, 0)

        // 対照: 同じ store の中身で fetchMe が成功（A）すれば記録できる。
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let resolved = Harness(session: scripted, token: "tA", seed: seed)
        await resolved.state.resolve()
        XCTAssertNotNil(resolved.records.record(episodeId: "f", seconds: 1, at: recordedAt))
        XCTAssertEqual(resolved.store.writeCount, 1)
        XCTAssertEqual(Set(resolved.records.unsent().map(\.episodeId)), ["ea", "f"])
    }

    // verifies: ios-dec-133, shared-dec-36, shared-sync-02
    // kills: 認証が確定していない間（または key が無い間）に束縛が残り、記録・送信ができる
    func testBindingIsNilWheneverSessionIsNotAuthenticated() async throws {
        let seed: [(SubjectKey, [PositionRecord])] = [(subjectA, [unsentRecord(subjectA, "ea")])]

        func assertRefused(_ harness: Harness, _ label: String, line: UInt = #line) {
            XCTAssertNil(harness.records.record(episodeId: "f", seconds: 1, at: recordedAt), label, line: line)
            XCTAssertEqual(harness.store.writeCount, 0, label, line: line)
            XCTAssertTrue(harness.records.unsent().isEmpty, label, line: line)
        }

        let resolving = Harness(seed: seed)
        assertRefused(resolving, "resolving")

        let anonymous = Harness(seed: seed)
        await anonymous.state.resolve()
        assertRefused(anonymous, "anonymous")

        let unavailable = Harness(
            session: MockURLSession(mode: .transportError(URLError(.notConnectedToInternet))),
            token: "tA", seed: seed)
        await unavailable.state.resolve()
        assertRefused(unavailable, "unavailable")

        let loggedOut = Harness(seed: seed)
        login(loggedOut, as: subjectA)
        await loggedOut.state.logout()
        loggedOut.store.resetCounts()
        assertRefused(loggedOut, "logout の後")

        // 認証済みでも user_id が欠落・形式不正（主体キーが無い）なら束縛は nil。
        for userId in [nil, "bad id"] as [String?] {
            let scripted = ScriptedURLSession()
            scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: userId))
            let keyless = Harness(session: scripted, token: "tA", seed: seed)
            await keyless.state.resolve()
            guard case .authenticated = keyless.state.session else { return XCTFail("認証は成功する") }
            assertRefused(keyless, "key なし: \(String(describing: userId))")
        }

        // 対照: key のある認証済みでは記録できる。
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let keyed = Harness(session: scripted, token: "tA", seed: seed)
        await keyed.state.resolve()
        XCTAssertNotNil(keyed.records.record(episodeId: "f", seconds: 1, at: recordedAt))
        XCTAssertEqual(keyed.store.writeCount, 1)
    }

    // MARK: - 合成 root

    // verifies: ios-dec-133, shared-sync-03
    // kills: 合成 root が位置の記録を配線しない（束縛・離脱・回収・Reporter・起動時の再送）
    func testCompositionRootWiresPositionRecords() throws {
        let appURL = SourceGrep.appRoot.appendingPathComponent("NewsListenAppApp.swift")
        let codeLines = SourceGrep.content(of: appURL)
            .components(separatedBy: "\n")
            .filter { !SourceGrep.isCommentLine($0) }
        func count(_ needle: String) -> Int { codeLines.filter { $0.contains(needle) }.count }

        XCTAssertEqual(codeLines.isEmpty, false, "NewsListenAppApp.swift を読めた")
        for needle in [
            "PositionRecords(store:", "clearPositionRecords:", "reclaimPositionRecords:", "positionRecords.bind(subject:",
            "records:", "connectivity:", "resendUnsentPositions()",
        ] {
            XCTAssertGreaterThanOrEqual(count(needle), 1, "合成 root に \(needle) の配線が無い")
        }
        XCTAssertEqual(count("PositionRecordFiles("), 1, "adapter の具象は合成 root の 1 か所だけで作る")
    }
}
