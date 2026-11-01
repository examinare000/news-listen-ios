import XCTest
@testable import NewsListenApp

/// 主体別の音声キャッシュに関わる `AppState` の振る舞い（離脱の後始末・④の直接交代・起動時の回収・logout の送信）。
///
/// `bindOfflineSubject`・`reclaimOfflineLibrary`・`clearOfflineLibrary` の呼出は `OfflineLibraryCallLog` に記録する。
/// 実行中のダウンロードの cancel は、`registerDownloads` に渡す実物の `OfflineDownloads` の保留中の取得が
/// `CancellationError` で終わることで観測する。
@MainActor
final class AppStateOfflineSubjectTests: XCTestCase {

    // MARK: - ヘルパー

    private func subject(
        _ username: String, key: SubjectKey?, displayName: String? = nil
    ) -> Subject {
        Subject(username: username, displayName: displayName ?? username, role: Role(rawValue: "user"), key: key)
    }

    private func receipt(_ token: String, _ subject: Subject) -> LoginReceipt {
        LoginReceipt(token: token, subject: subject)
    }

    private func meJSON(username: String = "alice", userId: String?) -> Data {
        let idPart = userId.map { #","user_id":"\#($0)""# } ?? ""
        return Data(#"{"username":"\#(username)","role":"user","display_name":"\#(username)"\#(idPart)}"#.utf8)
    }

    private func makeState(
        log: OfflineLibraryCallLog,
        session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200),
        store: SessionStore = InMemorySessionStore(),
        nowPlaying: NowPlayingCenterSpy = NowPlayingCenterSpy()
    ) -> AppState {
        makeSubjectAwareAppState(
            session: session,
            sessionStore: store,
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: log.clear,
            bindOfflineSubject: log.bind,
            reclaimOfflineLibrary: log.reclaim
        )
    }

    /// 取得を保留できる `OfflineDownloads`。保留中の取得は cancel を見ないので、cancel されたかは
    /// 解放後の `download` が `CancellationError` で終わることで分かる。
    @MainActor
    private final class HeldDownloadRig {
        let library: OfflineLibrary
        let downloads: OfflineDownloads
        private var task: Task<DownloadReceipt, Error>?

        init(subject: SubjectKey) {
            let library = OfflineLibrary(
                store: .live(cacheManager: AudioCacheManager(fileManager: AudioCacheManagerTests.MockFileManager())))
            library.bind(subject: subject)
            self.library = library
            // closure はクロージャ生成後に self を使うため、保留の状態は別の箱に持つ。
            let box = HoldBox()
            self.box = box
            downloads = OfflineDownloads(
                library: library,
                fetchEpisode: { id in
                    guard let playable = PlayableEpisode(
                        content: EpisodeContent(
                            id: id, title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
                            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
                            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil),
                        audioUrl: "https://cdn.example.com/a.mp3", serverPosition: 0) else {
                        throw DownloadFailure.invalidSource
                    }
                    return .playable(playable)
                },
                downloadAudio: { _ in
                    await box.hold()
                    return Data([1, 2, 3])
                },
                currentSubject: { subject }
            )
        }

        private let box: HoldBox

        /// 取得を始めて、保留に入るまで待つ。
        func start(_ id: String) async {
            task = Task { try await self.downloads.download(episodeId: id) }
            await box.waitUntilHeld()
        }

        /// 保留を解いて、`download` の結果を返す。
        func finish() async -> Result<DownloadReceipt, Error> {
            box.release()
            guard let task else { return .failure(CancellationError()) }
            return await task.result
        }
    }

    private final class HoldBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?
        private var isHeld = false
        private var isReleased = false

        func hold() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isReleased { lock.unlock(); c.resume(); return }
                continuation = c
                isHeld = true
                let w = waiter
                waiter = nil
                lock.unlock()
                w?.resume()
            }
        }

        func waitUntilHeld() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isHeld { lock.unlock(); c.resume(); return }
                waiter = c
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            isReleased = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    // MARK: - logout の送信（破棄前のトークン・await しない・DELETE を送らない）

    // verifies: ios-contract-21（logout は破棄前に捕捉したトークンで POST /auth/logout を送り、応答を待たない）
    // kills: トークン破棄の後に client を作って Bearer が消える／応答を await して logout() が戻らない
    func testLogoutSendsCapturedBearerWithoutAwaitingTheResponse() async {
        let store = InMemorySessionStore(token: "tok-1")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "POST", path: "/auth/logout")
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log, session: scripted, store: store)
        appState.completeLogin(receipt("tok-1", subject("alice", key: subjectA)))

        var returned = false
        let logoutTask = Task {
            await appState.logout()
            returned = true
        }
        await scripted.waitUntilRequested(method: "POST", path: "/auth/logout")
        for _ in 0..<100 where !returned { await Task.yield() }

        XCTAssertTrue(returned, "/auth/logout の応答が保留でも logout() は戻る")
        XCTAssertNil(store.token)
        XCTAssertNil(appState.currentSubject)
        guard case .anonymous = appState.session else {
            scripted.release(method: "POST", path: "/auth/logout", status: 200)
            await logoutTask.value
            return XCTFail("anonymous になるべき")
        }
        let logoutRequest = scripted.sentRequests.first { $0.httpMethod == "POST" && $0.url?.path == "/auth/logout" }
        XCTAssertEqual(logoutRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1", "破棄前のトークン")

        scripted.release(method: "POST", path: "/auth/logout", status: 200)
        await logoutTask.value
    }

    // verifies: ios-contract-21（logout で DELETE /notifications/device-tokens を送らない）
    func testLogoutDoesNotSendDeviceTokenUnregister() async {
        let scripted = ScriptedURLSession()
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tok-1"))
        appState.completeLogin(receipt("tok-1", subject("alice", key: subjectA)))
        appState.didRegisterDeviceToken("apns-1")
        await scripted.waitUntilRequested(method: "POST", path: "/notifications/device-tokens")

        await appState.logout()
        await scripted.waitUntilRequested(method: "POST", path: "/auth/logout")

        let deletes = scripted.sentRequests.filter { $0.httpMethod == "DELETE" && $0.url?.path == "/notifications/device-tokens" }
        XCTAssertTrue(deletes.isEmpty, "unregister の client 呼出は削除された")
    }

    // MARK: - ios-contract-21（shared-leave-06: 離脱で cancel と離脱主体の削除。順序は token nil → 遷移 → 後始末）

    // verifies: ios-contract-21.2
    // kills: 離脱主体を捕捉せず nil を渡す／後始末を token 破棄・遷移の前に走らせる／cancelDownloads を呼ばない
    func testSL06_logoutCancelsDownloadsAndClearsDepartingSubjectAfterTransition() async {
        let store = InMemorySessionStore(token: "tok-1")
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log, store: store)
        let rig = HeldDownloadRig(subject: subjectA)
        appState.registerDownloads(rig.downloads)
        appState.completeLogin(receipt("tok-1", subject("alice", key: subjectA)))
        await rig.start("p1")
        var tokenAtClear: String?? = .none
        var anonymousAtClear = false
        log.onClear = { _ in
            tokenAtClear = .some(store.token)
            if case .anonymous = appState.session { anonymousAtClear = true }
        }

        await appState.logout()

        XCTAssertEqual(log.clearCalls, [subjectA], "離脱主体 A の key で 1 回")
        XCTAssertEqual(tokenAtClear, .some(nil), "後始末が呼ばれた時点で token は nil")
        XCTAssertTrue(anonymousAtClear, "後始末が呼ばれた時点で session は anonymous")
        XCTAssertEqual(log.lastBindEvent, .bind(nil), "離脱で束縛は nil")
        let result = await rig.finish()
        guard case .failure(let error) = result else { return XCTFail("cancel されたのに保存された") }
        XCTAssertTrue(error is CancellationError, "実行中のダウンロードは cancel される（実際: \(error)）")
        XCTAssertFalse(rig.library.has("p1"))
    }

    // verifies: ios-contract-20.9（401 の離脱でも離脱主体の key が渡る）
    func testUnauthorizedLeaveClearsDepartingSubject() async {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log, session: MockURLSession(data: Data(), statusCode: 401), store: InMemorySessionStore(token: "tA"))
        appState.completeLogin(receipt("tA", subject("alice", key: subjectA)))

        await appState.refreshListeningStreak()

        guard case .anonymous = appState.session else { return XCTFail("anonymous になるべき") }
        XCTAssertEqual(log.clearCalls, [subjectA])
    }

    // verifies: ios-contract-21.6（registerDownloads が無くても離脱は失敗にならない）
    func testLogoutWithoutRegisteredDownloadsStillCompletes() async {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log, store: InMemorySessionStore(token: "tok-1"))
        appState.completeLogin(receipt("tok-1", subject("alice", key: subjectA)))

        await appState.logout()

        guard case .anonymous = appState.session else { return XCTFail("anonymous になるべき") }
        XCTAssertEqual(log.clearCalls, [subjectA])
        XCTAssertNil(appState.lastCleanupIncomplete)
    }

    // MARK: - ios-contract-21（shared-leave-07: authenticated(A) の間に別の主体 B で completeLogin）

    // verifies: ios-contract-21.2
    // kills: ④ で後始末を走らせない／A でなく B の key で削除する／束縛を B にしない／旧 downloads を cancel しない
    func testSL07_completeLoginAsAnotherSubjectRunsDepartureCleanupForTheFirst() async {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log)
        let rig = HeldDownloadRig(subject: subjectA)
        appState.registerDownloads(rig.downloads)
        appState.completeLogin(receipt("tA", subject("alice", key: subjectA)))
        await rig.start("p1")

        appState.completeLogin(receipt("tB", subject("bob", key: subjectB)))

        XCTAssertEqual(log.clearCalls, [subjectA], "A の key で 1 回")
        XCTAssertEqual(log.lastBindEvent, .bind(subjectB), "束縛は B")
        XCTAssertEqual(appState.currentSubject?.key, subjectB)
        guard case .authenticated(let user) = appState.session, user.username == "bob" else {
            _ = await rig.finish()
            return XCTFail("B は authenticated")
        }
        let result = await rig.finish()
        guard case .failure(let error) = result else { return XCTFail("cancel されたのに保存された") }
        XCTAssertTrue(error is CancellationError, "登録済みの旧 downloads が cancel される")
    }

    // MARK: - 同じ主体の再ログインは離脱ではない

    // verifies: ios-contract-21.2
    // kills: 同じ主体の再ログインで後始末や bind(nil) が走る／ダウンロードを cancel する
    func testCompleteLoginAsSameSubjectRunsNoCleanupAndKeepsTheBinding() async {
        let store = InMemorySessionStore()
        let log = OfflineLibraryCallLog()
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let appState = makeState(log: log, store: store, nowPlaying: nowPlaying)
        let rig = HeldDownloadRig(subject: subjectA)
        appState.registerDownloads(rig.downloads)
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(receipt("tA", subject("alice", key: subjectA, displayName: "Alice")))
        let eventsBefore = log.events
        await rig.start("p1")

        appState.completeLogin(receipt("tA2", subject("alice", key: subjectA, displayName: "Alice2")))

        XCTAssertEqual(log.events, eventsBefore, "bind も clear も増えない（bind(nil) も無い）")
        XCTAssertEqual(playback.stopForLogoutCallCount, 0)
        XCTAssertEqual(nowPlaying.clearCallCount, 0)
        XCTAssertEqual(appState.currentSubject?.displayName, "Alice2")
        XCTAssertEqual(appState.currentSubject?.key, subjectA)
        XCTAssertEqual(store.token, "tA2", "トークンは新しい値")
        let result = await rig.finish()
        guard case .success(.saved) = result else { return XCTFail("cancel されず保存される（実際: \(result)）") }
    }

    // verifies: ios-contract-21.2（key が両方 nil で username が同じ）
    func testCompleteLoginWithNilKeysAndSameUsernameRunsNoCleanup() {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log)
        appState.completeLogin(receipt("tA", subject("alice", key: nil)))

        appState.completeLogin(receipt("tA2", subject("alice", key: nil, displayName: "Alice2")))

        XCTAssertTrue(log.clearCalls.isEmpty)
        XCTAssertEqual(appState.currentSubject?.displayName, "Alice2")
    }

    // verifies: ios-contract-21.2（key が両方 nil で username が違えば別主体。離脱主体の key は nil）
    func testCompleteLoginWithNilKeysAndDifferentUsernameCleansUpOnce() {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log)
        appState.completeLogin(receipt("tA", subject("alice", key: nil)))

        appState.completeLogin(receipt("tB", subject("bob", key: nil)))

        XCTAssertEqual(log.clearCalls.count, 1)
        XCTAssertNil(log.clearCalls[0], "離脱主体の key は nil")
    }

    // verifies: ios-contract-21.2（片方だけ nil で username が同じ: key が nil → 非 nil になるときだけ bind）
    // kills: key の違いだけで別主体と見なして後始末する／bind を呼ばず束縛が nil のまま残る
    func testCompleteLoginWhenKeyAppearsForTheSameUsernameBindsOnce() {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log)
        appState.completeLogin(receipt("tA", subject("alice", key: nil)))
        let bindsBefore = log.bindCalls.count

        appState.completeLogin(receipt("tA2", subject("alice", key: subjectA)))

        XCTAssertTrue(log.clearCalls.isEmpty, "同じ主体なので後始末 0")
        XCTAssertEqual(log.bindCalls.count, bindsBefore + 1)
        XCTAssertEqual(log.lastBindEvent, .bind(subjectA))
        XCTAssertEqual(appState.currentSubject?.key, subjectA)
    }

    // verifies: ios-contract-21.2（片方だけ nil で username が同じ: key が非 nil → nil でも束縛を外さず key を保つ）
    // kills: session の key を nil にして束縛と食い違う／bind(nil) を呼ぶ／後始末を走らせる
    func testCompleteLoginWhenKeyDisappearsForTheSameUsernameKeepsKeyAndBinding() {
        let store = InMemorySessionStore()
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log, store: store)
        appState.completeLogin(receipt("tA", subject("alice", key: subjectA, displayName: "Alice")))
        let eventsBefore = log.events

        appState.completeLogin(receipt("tA2", subject("alice", key: nil, displayName: "Alice2")))

        XCTAssertEqual(log.events, eventsBefore, "bind も clear も増えない（bind(nil) も無い）")
        XCTAssertEqual(appState.currentSubject?.displayName, "Alice2")
        XCTAssertEqual(appState.currentSubject?.key, subjectA, "key は元の主体のものを保つ")
        XCTAssertEqual(store.token, "tA2")
    }

    // MARK: - ios-contract-21（shared-leave-08: unavailable では回収せず、retryResolve の確定で 1 回）

    // verifies: ios-contract-21
    // kills: unavailable 中に回収する／retryResolve 後の確定で回収しない
    func testSL08_reclaimIsDeferredWhileUnavailableAndRunsOnceAfterRetry() async {
        let log = OfflineLibraryCallLog()
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 503)
        let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tA"))

        await appState.refreshAuth()

        guard case .unavailable = appState.session else { return XCTFail("前提: unavailable") }
        XCTAssertTrue(log.reclaimCalls.isEmpty, "unavailable の間は回収しない")

        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        appState.retryResolve()
        XCTAssertTrue(log.reclaimCalls.isEmpty, "resolving の間も回収しない")
        await appState.refreshAuth()

        XCTAssertEqual(log.reclaimCalls, [subjectA], "確定した時点で 1 回")
    }

    // MARK: - ios-contract-21（shared-leave-09: unavailable のまま completeLogin で 1 回だけ）

    // verifies: ios-contract-21
    // kills: 回収済みの旗が無く、logout の後の login でもう一度回収する
    func testSL09_completeLoginWhileUnavailableReclaimsOnceAndNeverAgainInThatLaunch() async {
        let log = OfflineLibraryCallLog()
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 503)
        let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tA"))
        await appState.refreshAuth()
        guard case .unavailable = appState.session else { return XCTFail("前提: unavailable") }
        XCTAssertTrue(log.reclaimCalls.isEmpty)

        appState.completeLogin(receipt("tB", subject("bob", key: subjectB)))
        XCTAssertEqual(log.reclaimCalls, [subjectB], "unavailable のまま login で B を残して 1 回")

        await appState.logout()
        appState.completeLogin(receipt("tC", subject("carol", key: subjectA)))

        XCTAssertEqual(log.reclaimCalls, [subjectB], "同じ起動で 2 回目は走らない")
    }

    // verifies: ios-contract-21（(ii) で回収済みなら、その後の logout → login でも走らない）
    func testSL09_reclaimAfterResolvedAuthenticationIsNotRepeatedByLaterLogin() async {
        let log = OfflineLibraryCallLog()
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tA"))
        await appState.refreshAuth()
        XCTAssertEqual(log.reclaimCalls, [subjectA], "前提: (ii) で 1 回")

        await appState.logout()
        appState.completeLogin(receipt("tB", subject("bob", key: subjectB)))

        XCTAssertEqual(log.reclaimCalls, [subjectA])
    }

    // MARK: - ios-contract-21（shared-leave-10: user_id 欠落・形式不正）

    // verifies: ios-contract-21（key が無効なら全削除相当の reclaim(keeping: nil) と bind(nil)）
    // kills: 欠落で起動不能にする／nil でなく別の key を残す
    func testSL10_getMeWithoutValidUserIdReclaimsEverythingAndBindsNil() async {
        for userId in [nil, "bad id"] as [String?] {
            let log = OfflineLibraryCallLog()
            let scripted = ScriptedURLSession()
            scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: userId))
            let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tA"))

            await appState.refreshAuth()

            guard case .authenticated = appState.session else { return XCTFail("認証は成功する: \(String(describing: userId))") }
            XCTAssertNil(appState.currentSubject?.key)
            XCTAssertEqual(log.reclaimCalls, [nil])
            XCTAssertEqual(log.bindCalls, [nil])
        }
    }

    // MARK: - 起動時回収の 5 経路

    // verifies: ios-contract-21（経路 (i): トークン無し → anonymous → reclaim(nil)）
    func testReclaimOnceWithNilWhenThereIsNoSavedToken() async {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log)

        await appState.refreshAuth()

        guard case .anonymous = appState.session else { return XCTFail("anonymous になるべき") }
        XCTAssertEqual(log.reclaimCalls, [nil])
        XCTAssertTrue(log.bindCalls.isEmpty, "束縛は変えない")
    }

    // verifies: ios-contract-21（経路 (ii): getMe 成功 → bind して reclaim(keeping: key)。束縛が先）
    func testReclaimOnceKeepingTheResolvedSubjectAfterBinding() async {
        let log = OfflineLibraryCallLog()
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tA"))

        await appState.refreshAuth()

        XCTAssertEqual(log.events, [.bind(subjectA), .reclaim(subjectA)], "束縛の後に 1 回")
    }

    // verifies: ios-contract-21（経路 (iii): 401 → anonymous → reclaim(nil)）
    func testReclaimOnceWithNilWhenGetMeIsUnauthorized() async {
        let log = OfflineLibraryCallLog()
        let appState = makeState(
            log: log, session: MockURLSession(data: Data(), statusCode: 401), store: InMemorySessionStore(token: "tA"))

        await appState.refreshAuth()

        guard case .anonymous = appState.session else { return XCTFail("anonymous になるべき") }
        XCTAssertEqual(log.reclaimCalls, [nil])
    }

    // verifies: ios-contract-21（回収の失敗は lastCleanupIncomplete に載せて続行し、同じ起動では再実行しない）
    // kills: 失敗を黙殺する／失敗で旗を戻して再実行する／失敗で認証を止める
    func testFailedReclaimIsReportedAndNotRetriedInTheSameLaunch() async {
        struct ReclaimFailure: Error {}
        let log = OfflineLibraryCallLog()
        log.reclaimError = ReclaimFailure()
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: meJSON(userId: "user-a"))
        let appState = makeState(log: log, session: scripted, store: InMemorySessionStore(token: "tA"))

        await appState.refreshAuth()

        guard case .authenticated = appState.session else { return XCTFail("回収の失敗で認証は止まらない") }
        XCTAssertEqual(appState.lastCleanupIncomplete?.failedParts, [.offlineLibrary])
        await appState.logout()
        appState.completeLogin(receipt("tB", subject("bob", key: subjectB)))
        XCTAssertEqual(log.reclaimCalls, [subjectA], "旗は戻さない。同じ起動では 1 回きり")
    }

    // MARK: - updateCurrentSubject は主体キーを保つ

    // verifies: ios-contract-20.11（プロフィール更新は key を変えず、束縛も呼ばない）
    // kills: 差し替えた Subject の key（別の key／nil）をそのまま採る／再 bind する
    func testUpdateCurrentSubjectKeepsTheSubjectKeyAndDoesNotRebind() {
        let log = OfflineLibraryCallLog()
        let appState = makeState(log: log)
        appState.completeLogin(receipt("tA", subject("alice", key: subjectA, displayName: "Alice")))
        let eventsBefore = log.events

        appState.updateCurrentSubject(subject("alice", key: subjectB, displayName: "Alice2"), capturedAt: appState.subjectStamp)

        XCTAssertEqual(appState.currentSubject?.displayName, "Alice2", "表示名は更新される")
        XCTAssertEqual(appState.currentSubject?.key, subjectA, "key は元のまま")
        XCTAssertEqual(log.events, eventsBefore)
    }
}
