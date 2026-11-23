import XCTest
@testable import NewsListenApp

/// ios-slice-oracle-03: 主体の離脱（logout・401・直接交代）と起動時の回収の実行観測、合成 root・View の配線の字面の観測。
///
/// 実行の観測は `AppState` を直接組み、実 `PlaybackCoordinator`・実 `OfflineLibrary`・実 `PositionRecords` へ結ぶ。
/// 字面の観測は、正規表現と枝の抜き出しを合成の文字列で正例・負例に通してから、本物のファイルに当てる。
@MainActor
final class DepartureContractOracleTests: XCTestCase {

    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 組み立て

    private func subject(_ username: String, key: SubjectKey?) -> Subject {
        Subject(username: username, displayName: username, role: Role(rawValue: "user"), key: key)
    }

    private func receipt(_ token: String, _ username: String, _ key: SubjectKey?) -> LoginReceipt {
        LoginReceipt(token: token, subject: subject(username, key: key))
    }

    @MainActor
    private final class KeyLog {
        private(set) var keys: [SubjectKey?] = []
        func record(_ key: SubjectKey?) { keys.append(key) }
        var names: [String?] { keys.map { $0?.rawValue } }
    }

    @MainActor
    private final class CallCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// `AppState(...)` を直接組む。後始末の各手順の呼出を記録する。
    @MainActor
    private final class DirectRig {
        let state: AppState
        let store: InMemorySessionStore
        let lifecycle = PlaybackLifecycleSpy()
        let nowPlaying = NowPlayingCenterSpy()
        let preferenceClears = CallCounter()
        let offlineClears = KeyLog()
        let positionClears = KeyLog()

        init(session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200), token: String? = nil) {
            let store = InMemorySessionStore(token: token)
            self.store = store
            let nowPlaying = self.nowPlaying
            let preferenceClears = self.preferenceClears
            let offlineClears = self.offlineClears
            let positionClears = self.positionClears
            state = AppState(
                sessionStore: store,
                accountGatewayFactory: { token, onUnauthorized in
                    AccountGateway.live(apiClient: APIClient(
                        baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token,
                        session: session, onUnauthorized: onUnauthorized))
                },
                clearSubjectPreferences: { preferenceClears.increment() },
                nowPlayingCenter: nowPlaying,
                clearOfflineLibrary: { key in offlineClears.record(key) },
                clearPositionRecords: { key in positionClears.record(key) })
            state.registerPlaybackLifecycle(lifecycle)
        }
    }

    private enum Departure: String, CaseIterable {
        case logout, unauthorized, directSwap
    }

    private func depart(_ departure: Departure, _ state: AppState) async {
        switch departure {
        case .logout: await state.logout()
        case .unauthorized: state.handle(failure: .unauthorized, sentToken: "tA")
        case .directSwap: state.completeLogin(receipt("tB", "bob", subjectB))
        }
    }

    /// 音声の実体を保持する `OfflineLibrary`。`cacheSize(subject:)` を読むために `AudioCacheManager` を手元に持つ。
    @MainActor
    private final class LibraryRig {
        let cache = AudioCacheManager(fileManager: AudioCacheManagerTests.MockFileManager())
        let library: OfflineLibrary
        init() { library = OfflineLibrary(store: .live(cacheManager: cache)) }
        func size(_ key: SubjectKey) -> Int64 { cache.cacheSize(subject: key) }
    }

    private func unsentRecord(_ key: SubjectKey, _ id: String) -> PositionRecord {
        PositionRecord(subject: key, episodeId: id, seconds: 10, recordedAt: recordedAt, isSent: false)
    }

    /// 合成 root と同じ形で `AppState`・実 `PositionRecords`・実 `OfflineLibrary`・実 `PositionReporter` を結ぶ。
    @MainActor
    private final class PositionRig {
        let store = InMemoryPositionStore()
        let records: PositionRecords
        let libraryRig = LibraryRig()
        let gateway = RecordingPlaybackGateway(response: { EntryFixture.playable($0) })
        let reporter: PositionReporter
        let state: AppState

        init(urlSession: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200), token: String? = nil) {
            let records = PositionRecords(store: store.store)
            self.records = records
            let library = libraryRig.library
            reporter = PositionReporter(
                updatePosition: gateway.updatePosition,
                markCompleted: gateway.markCompleted,
                onPositionSaved: { _ in },
                onCompletionRecorded: {},
                beginBackgroundTask: { {} },
                records: records,
                connectivity: makeSilentConnectivity())
            state = AppState(
                sessionStore: InMemorySessionStore(token: token),
                accountGatewayFactory: { token, onUnauthorized in
                    AccountGateway.live(apiClient: APIClient(
                        baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token,
                        session: urlSession, onUnauthorized: onUnauthorized))
                },
                nowPlayingCenter: NowPlayingCenterSpy(),
                clearOfflineLibrary: { key in try library.remove(subject: key) },
                bindOfflineSubject: { key in
                    library.bind(subject: key)
                    records.bind(subject: key)
                },
                reclaimOfflineLibrary: { key in try library.reclaim(keeping: key) },
                clearPositionRecords: { key in if let key { try records.remove(subject: key) } },
                reclaimPositionRecords: { key in try records.reclaim(keeping: key) })
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

    // MARK: - 実行の観測

    // verifies: shared-leave-07, ios-contract-21
    // kills: 直接交代で再生の停止・ロック画面の消去・設定の既定化・音声と記録の消去のどれかを省く／離脱主体でない key を渡す／新しい主体の確立を後始末の後ろへ回す
    func testDirectSwapRunsEveryCleanupStepOnce() {
        let rig = DirectRig()
        var keyAtStop: [SubjectKey?] = []
        rig.lifecycle.onStopForLogout = { keyAtStop.append(rig.state.currentSubject?.key) }

        rig.state.completeLogin(receipt("tA", "alice", subjectA))
        XCTAssertEqual(rig.lifecycle.stopForLogoutCallCount, 0, "対照: 最初の login では後始末しない")
        XCTAssertEqual(rig.nowPlaying.clearCallCount, 0)
        XCTAssertEqual(rig.preferenceClears.count, 0)
        XCTAssertEqual(rig.offlineClears.names, [])
        XCTAssertEqual(rig.positionClears.names, [])

        rig.state.completeLogin(receipt("tB", "bob", subjectB))

        XCTAssertEqual(rig.lifecycle.stopForLogoutCallCount, 1, "再生の停止")
        XCTAssertEqual(rig.nowPlaying.clearCallCount, 1, "ロック画面の消去")
        XCTAssertEqual(rig.preferenceClears.count, 1, "設定の既定化")
        XCTAssertEqual(rig.offlineClears.names, [subjectA.rawValue], "音声は離脱主体の分を消す")
        XCTAssertEqual(rig.positionClears.names, [subjectA.rawValue], "位置の記録は離脱主体の分を消す")
        XCTAssertEqual(keyAtStop.map { $0?.rawValue }, [subjectB.rawValue], "後始末の時点で新しい主体は確立済み")
    }

    // verifies: shared-leave-01, shared-leave-02, shared-leave-07
    // kills: 離脱で再生を止めない／離脱で再生の queue を空にしない／離脱の入口のどれかが再生の停止を呼ばない
    func testLeavingStopsRealPlaybackAndEmptiesNowPlayingForEveryEntry() async throws {
        for departure in Departure.allCases {
            let rig = PlaybackEntryRig()
            let direct = DirectRig(token: "tA")
            direct.state.registerPlaybackLifecycle(rig.coordinator)
            direct.state.completeLogin(receipt("tA", "alice", subjectA))
            try await rig.play("e")
            XCTAssertNotEqual(rig.coordinator.presentation, .hidden, "前提(\(departure)): 表示が出ている")
            XCTAssertNotNil(rig.coordinator.nowPlaying(), "前提(\(departure)): 再生中")

            await depart(departure, direct.state)

            XCTAssertEqual(rig.coordinator.session.stateKind, "idle", "\(departure)")
            XCTAssertTrue(rig.coordinator.queue.items.isEmpty, "\(departure)")
            XCTAssertNil(rig.coordinator.nowPlaying(), "\(departure)")
            XCTAssertEqual(rig.coordinator.presentation, .hidden, "\(departure)")
        }

        // 対照: 同じ主体の再認証は離脱ではなく、再生は続く。
        let rig = PlaybackEntryRig()
        let direct = DirectRig(token: "tA")
        direct.state.registerPlaybackLifecycle(rig.coordinator)
        direct.state.completeLogin(receipt("tA", "alice", subjectA))
        try await rig.play("e")
        direct.state.completeLogin(receipt("tA2", "alice", subjectA))
        XCTAssertNotNil(rig.coordinator.nowPlaying(), "離脱しないときは再生が残る")
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing")
    }

    // verifies: shared-leave-01, shared-leave-02, shared-leave-07
    // kills: 再生中のときだけ停止を呼ぶ実装で、確認を開いた一時停止中の離脱が確認・queue・表示を残す
    func testLeavingWhilePausedClosesAnOpenResumeChoiceForEveryEntry() async throws {
        for departure in Departure.allCases {
            let rig = PlaybackEntryRig()
            let direct = DirectRig(token: "tA")
            direct.state.registerPlaybackLifecycle(rig.coordinator)
            direct.state.completeLogin(receipt("tA", "alice", subjectA))
            try await rig.pausedWithOtherDevice("e")
            rig.coordinator.toggleFromScreen()
            XCTAssertNotNil(rig.coordinator.resumeChoice, "前提(\(departure)): 確認が開いている")
            XCTAssertEqual(rig.coordinator.session.stateKind, "paused", "前提(\(departure))")

            await depart(departure, direct.state)

            XCTAssertNil(rig.coordinator.resumeChoice, "\(departure)")
            XCTAssertEqual(rig.coordinator.session.stateKind, "idle", "\(departure)")
            XCTAssertTrue(rig.coordinator.queue.items.isEmpty, "\(departure)")
            XCTAssertEqual(rig.coordinator.presentation, .hidden, "\(departure)")
        }
    }

    // verifies: shared-leave-07, ios-contract-21
    // kills: 直接交代で離脱主体の音声が残る／設定の既定化を省く／新しい主体の音声を消す
    func testDirectSwapEmptiesTheDepartingAudioDirectoryAndSubjectScopedKeys() throws {
        let suite = UserDefaults(suiteName: "DepartureContractOracleTests.\(UUID().uuidString)")!
        let keys = PreferenceRegistry(defaults: suite).subjectScopedKeys
        XCTAssertFalse(keys.isEmpty, "前提: 主体依存の key を registry から得られる")
        let libraries = LibraryRig()
        let library = libraries.library
        let harness = makeAppStateHarness(
            defaults: suite,
            clearOfflineLibrary: { try library.remove(subject: $0) },
            bindOfflineSubject: { library.bind(subject: $0) })

        harness.state.completeLogin(receipt("tA", "alice", subjectA))
        for key in keys { suite.set("value", forKey: key) }
        for key in keys { XCTAssertNotNil(suite.object(forKey: key), "前提: \(key) に値を置けた") }
        try library.save(Data([1, 2, 3]), for: "e", subject: subjectA)
        try library.save(Data([4, 5, 6]), for: "f", subject: subjectB)
        XCTAssertGreaterThan(libraries.size(subjectA), 0, "前提: 離脱前は A の実体がある")
        XCTAssertGreaterThan(libraries.size(subjectB), 0, "前提: B の実体がある")

        harness.state.completeLogin(receipt("tB", "bob", subjectB))

        XCTAssertEqual(libraries.size(subjectA), 0, "A のディレクトリは空")
        for key in keys { XCTAssertNil(suite.object(forKey: key), "主体依存の key \(key) は消える") }
        XCTAssertGreaterThan(libraries.size(subjectB), 0, "対照: B の実体は残る")
    }

    // verifies: shared-leave-02
    // kills: 失効の離脱で、後始末の完了を待ってから anonymous にする
    func testUnauthorizedTransitionDoesNotWaitForCleanup() async throws {
        let unauthorized = DirectRig(token: "tA")
        unauthorized.state.completeLogin(receipt("tA", "alice", subjectA))
        var atStop: (anonymous: Bool, token: String?)?
        unauthorized.lifecycle.onStopForLogout = {
            atStop = (unauthorized.state.session == .anonymous, unauthorized.store.token)
        }
        unauthorized.state.handle(failure: .unauthorized, sentToken: "tA")
        let observed = try XCTUnwrap(atStop, "後始末が走った")
        XCTAssertTrue(observed.anonymous, "後始末の時点で anonymous")
        XCTAssertNil(observed.token, "後始末の時点で token は nil")

        let loggedOut = DirectRig(token: "tA")
        loggedOut.state.completeLogin(receipt("tA", "alice", subjectA))
        var atStopLogout: (anonymous: Bool, token: String?)?
        loggedOut.lifecycle.onStopForLogout = {
            atStopLogout = (loggedOut.state.session == .anonymous, loggedOut.store.token)
        }
        await loggedOut.state.logout()
        let observedLogout = try XCTUnwrap(atStopLogout, "対照: logout でも後始末が走った")
        XCTAssertTrue(observedLogout.anonymous)
        XCTAssertNil(observedLogout.token)
    }

    // verifies: shared-leave-08
    // kills: unavailable の間に回収する／未認証への確定で回収しない／確定の回収で音声の実体が消えない
    func testUnavailableKeepsCachedAudioUntilAnonymousReclaimsItOnce() async throws {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 503)
        let libraries = LibraryRig()
        let library = libraries.library
        let reclaims = KeyLog()
        let state = AppState(
            sessionStore: InMemorySessionStore(token: "tA"),
            accountGatewayFactory: { token, onUnauthorized in
                AccountGateway.live(apiClient: APIClient(
                    baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token,
                    session: scripted, onUnauthorized: onUnauthorized))
            },
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: { _ in },
            reclaimOfflineLibrary: { key in
                reclaims.record(key)
                try library.reclaim(keeping: key)
            })
        try library.save(Data([1, 2, 3]), for: "e", subject: subjectA)
        XCTAssertGreaterThan(libraries.size(subjectA), 0, "前提: 解決の前に A の実体がある")

        await state.resolve()

        guard case .unavailable = state.session else { return XCTFail("前提: unavailable") }
        XCTAssertEqual(reclaims.names, [], "unavailable の間は回収しない")
        XCTAssertGreaterThan(libraries.size(subjectA), 0, "unavailable の間は A の実体が残る")

        scripted.configure(method: "GET", path: "/auth/me", status: 401)
        state.retryResolve()
        XCTAssertEqual(state.session, .resolving, "再試行の直後は解決中")
        XCTAssertEqual(reclaims.names, [], "解決中も回収しない")

        await state.resolve()

        XCTAssertEqual(state.session, .anonymous)
        XCTAssertEqual(reclaims.names, [nil], "未認証への確定で 1 回（keeping なし）")
        XCTAssertEqual(libraries.size(subjectA), 0, "確定の回収で A の実体が消える")
    }

    // verifies: shared-leave-11, shared-leave-07
    // kills: 直接交代で離脱主体の未送信を送る／新しい主体の送信済みの記録を消す／離脱主体の記録が残る
    func testDirectSwapKeepsTheNewSubjectsRecordsAndSendsNothingOfTheOld() async throws {
        let rig = PositionRig()
        rig.state.completeLogin(receipt("tA", "alice", subjectA))
        rig.records.record(episodeId: "e", seconds: 10, at: recordedAt)
        XCTAssertEqual(rig.store.stored(for: subjectA).map(\.episodeId), ["e"], "前提: A の未送信がある")
        rig.store.seed([PositionRecord(
            subject: subjectB, episodeId: "b", seconds: 5, recordedAt: recordedAt, isSent: true)], for: subjectB)

        rig.state.completeLogin(receipt("tB", "bob", subjectB))
        let sent = await rig.resendAndCountSends()

        XCTAssertTrue(rig.store.stored(for: subjectA).isEmpty, "A の記録は消える")
        XCTAssertEqual(rig.store.stored(for: subjectB).map(\.episodeId), ["b"], "B の送信済みの記録は残る")
        XCTAssertEqual(sent, 0, "A の未送信を送らない")

        // 対照: 直接交代をしなければ、同じ手順の未送信は再送で送られる。
        let control = PositionRig()
        control.state.completeLogin(receipt("tA", "alice", subjectA))
        control.records.record(episodeId: "e", seconds: 10, at: recordedAt)
        let controlSent = await control.resendAndCountSends()
        XCTAssertEqual(controlSent, 1, "対照: 交代しなければ送られる")
    }

    // verifies: shared-leave-09, shared-leave-11
    // kills: unavailable の間に回収する／unavailable から login したときに前の主体の音声・記録を回収しない／新しい主体の分まで消す
    func testUnavailableThenLoginKeepsOnlyTheNewSubjectsAssets() async throws {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 503)
        let rig = PositionRig(urlSession: scripted, token: "tA")
        let library = rig.libraryRig.library
        try library.save(Data([1, 2, 3]), for: "ea", subject: subjectA)
        try library.save(Data([4, 5, 6]), for: "eb", subject: subjectB)
        rig.store.seed([unsentRecord(subjectA, "ea")], for: subjectA)
        rig.store.seed([unsentRecord(subjectB, "eb")], for: subjectB)

        await rig.state.resolve()

        guard case .unavailable = rig.state.session else { return XCTFail("前提: unavailable") }
        XCTAssertNil(rig.state.currentSubject, "unavailable では主体が無い")
        XCTAssertGreaterThan(rig.libraryRig.size(subjectA), 0)
        XCTAssertGreaterThan(rig.libraryRig.size(subjectB), 0)
        XCTAssertEqual(rig.store.stored(for: subjectA).map(\.episodeId), ["ea"])
        XCTAssertEqual(rig.store.stored(for: subjectB).map(\.episodeId), ["eb"])

        rig.state.completeLogin(receipt("tB", "bob", subjectB))

        XCTAssertEqual(rig.libraryRig.size(subjectA), 0, "A の音声は消える")
        XCTAssertTrue(rig.store.stored(for: subjectA).isEmpty, "A の記録は消える")
        XCTAssertGreaterThan(rig.libraryRig.size(subjectB), 0, "B の音声は残る")
        XCTAssertEqual(rig.store.stored(for: subjectB).map(\.episodeId), ["eb"], "B の記録は残る")
    }

    // MARK: - 字面の観測（合成 root・View の配線）

    /// 非コメント行。読めた行が空でないことを要求する。
    private func codeLines(_ relative: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let lines = ResumeWiringSource.codeLines(in: SourceGrep.appRoot.appendingPathComponent(relative))
        XCTAssertFalse(lines.isEmpty, "\(relative) を読めた", file: file, line: line)
        return lines
    }

    private func hit(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func hitCount(_ pattern: String, in lines: [String]) -> Int {
        lines.filter { hit(pattern, $0) }.count
    }

    /// `anchor` を含む最初の行より後で `label` から始まる枝を抜き出す。枝は label の次の行から、
    /// indent が label 以下で `case `・`default`・`@unknown default`・`}` のどれかで始まる最初の行の手前まで。
    /// `outside` は枝以外の（anchor 以降の）行。
    private func branch(label: String, after anchor: String, in lines: [String]) -> (body: [String], outside: [String])? {
        guard let anchorIndex = lines.firstIndex(where: { $0.contains(anchor) }),
              let labelIndex = lines[anchorIndex...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix(label)
              }) else { return nil }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        let labelIndent = indent(lines[labelIndex])
        var end = lines.count
        for index in (labelIndex + 1)..<lines.count {
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            let isBoundary = ["case ", "default", "@unknown default", "}"].contains { text.hasPrefix($0) }
            if indent(lines[index]) <= labelIndent && isBoundary {
                end = index
                break
            }
        }
        let body = Array(lines[(labelIndex + 1)..<end])
        let outside = Array(lines[anchorIndex..<(labelIndex + 1)]) + Array(lines[end...])
        return (body, outside)
    }

    private let loginViewModelEntry = (shape: #"[^y]LoginViewModel\("#, onSuccess: #"onSuccess: onSuccess\)"#)
    private let passkeyViewModelEntry = (shape: #"PasskeyLoginViewModel\("#, onSuccess: #"onSuccess: onSuccess\)"#)

    private func entryCount(_ entry: (shape: String, onSuccess: String), in lines: [String]) -> Int {
        lines.filter { hit(entry.shape, $0) && hit(entry.onSuccess, $0) }.count
    }

    // verifies: shared-leave-09
    // kills: login 画面の入口の 1 つが、主体の確定を通さない onSuccess を渡す
    func testLoginViewPassesTheSameOnSuccessToBothEntries() {
        let password = "        _viewModel = StateObject(wrappedValue: LoginViewModel(authentication: authentication, onSuccess: onSuccess))"
        let passkey = "        _passkeyViewModel = StateObject(wrappedValue: PasskeyLoginViewModel(signIn: passkeySignIn, onSuccess: onSuccess))"
        let passwordDropped = password.replacingOccurrences(of: "onSuccess: onSuccess", with: "onSuccess: { _ in }")
        let passkeyDropped = passkey.replacingOccurrences(of: "onSuccess: onSuccess", with: "onSuccess: { _ in }")
        XCTAssertEqual(entryCount(loginViewModelEntry, in: [password, passkey]), 1, "合成: password の行だけに一致する")
        XCTAssertEqual(entryCount(passkeyViewModelEntry, in: [password, passkey]), 1, "合成: passkey の行だけに一致する")
        XCTAssertEqual(entryCount(loginViewModelEntry, in: [passwordDropped, passkey]), 0, "合成: 落とした入口は一致しない")
        XCTAssertEqual(entryCount(passkeyViewModelEntry, in: [password, passkeyDropped]), 0, "合成: 落とした入口は一致しない")

        let lines = codeLines("Auth/LoginView.swift")
        XCTAssertEqual(entryCount(loginViewModelEntry, in: lines), 1, "password の入口")
        XCTAssertEqual(entryCount(passkeyViewModelEntry, in: lines), 1, "passkey の入口")
    }

    // verifies: shared-leave-09
    // kills: root の login の完了 closure が主体の確定を通らない／確定の呼び手が 2 つに増える
    func testRootHasExactlyOneCompleteLoginEntry() {
        let lines = codeLines("NewsListenAppApp.swift")
        XCTAssertEqual(lines.filter { $0.contains("appState.completeLogin(") }.count, 1)
    }

    private let retryButton = #"Button\("再試行"\)\s*\{\s*appState\.retryResolve\(\)\s*\}"#

    // verifies: shared-leave-03
    // kills: unavailable の枝から再試行のボタンを外す／ボタンを別の枝へ移す
    func testUnavailableBranchOffersRetryButton() throws {
        let synthetic = """
            switch appState.session {
            case .anonymous:
                Button("再試行") { appState.retryResolve() }
            case .unavailable:
                Text("x")
            }
        """.components(separatedBy: "\n")
        let wrong = try XCTUnwrap(branch(label: "case .unavailable:", after: "switch appState.session", in: synthetic))
        XCTAssertEqual(wrong.body.count, 1, "合成: 枝は次の行から閉じ括弧の手前まで")
        XCTAssertEqual(hitCount(retryButton, in: wrong.body), 0, "合成: 別の枝のボタンは unavailable の枝に入らない")
        XCTAssertEqual(hitCount(retryButton, in: wrong.outside), 1, "合成: ボタンは枝の外にある")
        let right = """
            switch appState.session {
            case .anonymous:
                Text("x")
            case .unavailable:
                Button("再試行") { appState.retryResolve() }
            }
        """.components(separatedBy: "\n")
        let rightBranch = try XCTUnwrap(branch(label: "case .unavailable:", after: "switch appState.session", in: right))
        XCTAssertEqual(hitCount(retryButton, in: rightBranch.body), 1, "合成: 枝の中のボタンに一致する")

        let lines = codeLines("NewsListenAppApp.swift")
        let found = try XCTUnwrap(
            branch(label: "case .unavailable:", after: "switch appState.session", in: lines), "unavailable の枝を抜き出せた")
        XCTAssertFalse(found.body.isEmpty, "枝が空でない")
        XCTAssertEqual(hitCount(retryButton, in: found.body), 1, "unavailable の枝に再試行のボタンがある")
        XCTAssertEqual(hitCount(retryButton, in: found.outside), 0, "ほかの枝にはない")
    }

    // verifies: shared-sync-01
    // kills: 背景遷移の枝を消す／位置の同期を active の枝へ移す
    func testBackgroundAndInactiveFlushThePositionAndActiveDoesNot() throws {
        let flush = #"playerViewModel\.flushPosition\(\)"#
        let synthetic = """
            switch newPhase {
            case .active:
                playerViewModel.flushPosition()
            case .background, .inactive:
                Task { }
            @unknown default:
                break
            }
        """.components(separatedBy: "\n")
        let movedBackground = try XCTUnwrap(
            branch(label: "case .background, .inactive:", after: "switch newPhase", in: synthetic))
        XCTAssertEqual(hitCount(flush, in: movedBackground.body), 0, "合成: 背景の枝に無い")
        let movedActive = try XCTUnwrap(branch(label: "case .active:", after: "switch newPhase", in: synthetic))
        XCTAssertEqual(hitCount(flush, in: movedActive.body), 1, "合成: active の枝にある")

        let lines = codeLines("NewsListenAppApp.swift")
        let background = try XCTUnwrap(
            branch(label: "case .background, .inactive:", after: ".onChange(of: scenePhase)", in: lines), "背景の枝を抜き出せた")
        XCTAssertFalse(background.body.isEmpty)
        XCTAssertEqual(hitCount(flush, in: background.body), 1, "背景・非アクティブの枝で位置を同期する")
        let active = try XCTUnwrap(
            branch(label: "case .active:", after: ".onChange(of: scenePhase)", in: lines), "active の枝を抜き出せた")
        XCTAssertFalse(active.body.isEmpty)
        XCTAssertEqual(hitCount("flushPosition", in: active.body), 0, "active の枝では同期しない")
    }

    // verifies: ios-contract-13, ios-dec-181
    // kills: 位置の保存の応答を一覧へ反映しない（onPositionSaved を空の closure にする）
    func testPositionReporterIsBuiltWithOnPositionSavedApplyingToTheCatalog() {
        let wiring = #"onPositionSaved:\s*\{\s*episode\s+in\s+catalog\.applyPositionSaved\(episode\)\s*\}"#
        XCTAssertTrue(hit(wiring, "            onPositionSaved: { episode in catalog.applyPositionSaved(episode) },"), "合成: 正例")
        XCTAssertFalse(hit(wiring, "            onPositionSaved: { _ in },"), "合成: 空の closure は一致しない")

        let root = SourceGrep.appRoot.appendingPathComponent("NewsListenAppApp.swift")
        let construction = ResumeWiringSource.constructionLines(in: root, opening: "PositionReporter(")
        XCTAssertFalse(construction.isEmpty, "PositionReporter の構築を読めた")
        XCTAssertGreaterThanOrEqual(hitCount(wiring, in: construction), 1)
    }

    // verifies: shared-sync-14
    // kills: 確認の表示条件を常に false にする／ミニとフルの両方に出す
    func testResumeChoiceIsPresentedOnlyWhileActiveAndOnlyOnTheForegroundPlayer() {
        let getter = #"get:\s*\{\s*isActive\s*&&\s*vm\.resumeChoice\s*!=\s*nil\s*\}"#
        let mini = #"resumeChoiceDialog\(vm,\s*isActive:\s*vm\.presentation\s*==\s*\.mini\)"#
        let expanded = #"resumeChoiceDialog\(vm,\s*isActive:\s*vm\.presentation\s*==\s*\.expanded\)"#
        XCTAssertTrue(hit(getter, "            get: { isActive && vm.resumeChoice != nil },"), "合成: 正例")
        XCTAssertFalse(hit(getter, "            get: { false },"), "合成: 常に false は一致しない")
        XCTAssertFalse(hit(getter, "            get: { vm.resumeChoice != nil },"), "合成: isActive を外したものは一致しない")
        XCTAssertTrue(hit(mini, "        .resumeChoiceDialog(vm, isActive: vm.presentation == .mini)"), "合成: 正例")
        XCTAssertFalse(hit(mini, "        .resumeChoiceDialog(vm, isActive: vm.presentation == .expanded)"), "合成: 反対側は一致しない")
        XCTAssertFalse(hit(mini, "        .resumeChoiceDialog(vm, isActive: true)"), "合成: true は一致しない")

        let choice = codeLines("Podcast/ResumeChoiceView.swift")
        XCTAssertEqual(hitCount(getter, in: choice), 1, "isPresented の getter")
        let miniLines = codeLines("Podcast/MiniPlayerView.swift")
        XCTAssertEqual(miniLines.filter { $0.contains("resumeChoiceDialog(") }.count, 1)
        XCTAssertEqual(hitCount(mini, in: miniLines), 1, "ミニは .mini のときだけ")
        let sheetLines = codeLines("Podcast/PlayerSheetView.swift")
        XCTAssertEqual(sheetLines.filter { $0.contains("resumeChoiceDialog(") }.count, 1)
        XCTAssertEqual(hitCount(expanded, in: sheetLines), 1, "シートは .expanded のときだけ")
    }

    private let settingConstruction = #"PreferenceSetting\s*(<[^>]*>)?\s*\("#
    private let registryPath = "Settings/PreferenceRegistry.swift"

    /// 列 0 の `}` で閉じる宣言の本体（`opening` を含む最初の行の次から）。
    private func declarationBody(opening: String, in lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: { $0.contains(opening) }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0 == "}" }) ?? lines.endIndex
        return Array(lines[(start + 1)..<end])
    }

    // verifies: ios-contract-23, ios-dec-182
    // kills: registry の外で設定を構築できる（構築を registry の外に足す／init を internal にする）
    func testPreferenceSettingsCannotBeBuiltOutsideTheRegistry() throws {
        XCTAssertTrue(hit(settingConstruction, "        PreferenceSetting(key: \"a\", scope: .device)"), "合成: 通常の構築")
        XCTAssertTrue(hit(settingConstruction, "        PreferenceSetting<Bool>(key: \"a\")"), "合成: 型引数付きの構築")
        XCTAssertFalse(hit(settingConstruction, "    func get<Value>(_ setting: PreferenceSetting<Value>) -> Value {"), "合成: 型の参照は構築でない")
        let privateInit = ["    fileprivate init(", "        key: String,"]
        let openInit = ["    init(", "        key: String,"]
        XCTAssertEqual(initDeclarations(in: privateInit).filter { $0.hasPrefix("fileprivate init(") }.count, 1)
        XCTAssertEqual(initDeclarations(in: openInit).filter { $0.hasPrefix("fileprivate init(") }.count, 0, "合成: internal の init は一致しない")

        let all = SourceGrep.swiftFiles()
        XCTAssertFalse(all.isEmpty, "production のファイルを読めた")
        let hits = SourceGrep.matchingLines(pattern: settingConstruction, in: all)
            .filter { !SourceGrep.isCommentLine($0.text) }
        XCTAssertTrue(hits.contains { $0.path == registryPath }, "registry の中に構築がある")
        XCTAssertEqual(hits.filter { $0.path != registryPath }.map(\.path), [], "registry の外に構築は無い")

        let registry = codeLines(registryPath)
        let body = try XCTUnwrap(declarationBody(opening: "struct PreferenceSetting", in: registry), "struct の本体を抜き出せた")
        XCTAssertFalse(body.isEmpty)
        let inits = initDeclarations(in: body)
        XCTAssertGreaterThanOrEqual(inits.count, 1, "init の宣言がある")
        XCTAssertEqual(inits.filter { !$0.hasPrefix("fileprivate init(") }, [], "init はすべて fileprivate")
    }

    private func initDeclarations(in lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { hit(#"(^|[^A-Za-z0-9_])init\s*\("#, $0) }
    }

    // verifies: ios-contract-23, ios-dec-182
    // kills: registry の get・set に文字列 key を取る overload を足す
    func testRegistryGetAndSetAcceptOnlyTypedSettings() throws {
        func declarations(_ name: String, in lines: [String]) -> [String] {
            lines.filter { hit("func\\s+\(name)\\s*(<[^>]*>)?\\s*\\(", $0) }
        }
        func typed(_ name: String) -> String { "func\\s+\(name)\\s*(<[^>]*>)?\\s*\\(\\s*_\\s+setting:\\s*PreferenceSetting<" }
        let syntheticGood = [
            "    func get<Value>(_ setting: PreferenceSetting<Value>) -> Value {",
            "    func set<Value>(_ setting: PreferenceSetting<Value>, _ value: Value) -> Bool {",
            "    func getAll() -> Int {",
        ]
        let syntheticBad = syntheticGood + [
            "    func get(_ key: String) -> Any? {",
            "    func set(_ key: String, _ value: Any) {",
        ]
        for name in ["get", "set"] {
            XCTAssertEqual(declarations(name, in: syntheticGood).count, 1, "合成: \(name) の宣言を数える（別名は数えない）")
            XCTAssertEqual(declarations(name, in: syntheticGood).filter { !hit(typed(name), $0) }, [], "合成: 型付きだけなら通る")
            XCTAssertEqual(declarations(name, in: syntheticBad).filter { !hit(typed(name), $0) }.count, 1, "合成: 文字列 key の overload を拾う")
        }

        let registry = codeLines(registryPath)
        let body = try XCTUnwrap(declarationBody(opening: "final class PreferenceRegistry", in: registry), "class の本体を抜き出せた")
        XCTAssertFalse(body.isEmpty)
        for name in ["get", "set"] {
            let found = declarations(name, in: body)
            XCTAssertGreaterThanOrEqual(found.count, 1, "\(name) の宣言がある")
            XCTAssertEqual(found.filter { !hit(typed(name), $0) }, [], "\(name) の第 1 引数はすべて型付きの設定")
        }
    }
}
