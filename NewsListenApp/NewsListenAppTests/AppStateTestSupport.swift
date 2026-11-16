import XCTest
@testable import NewsListenApp

// ios-slice-auth-01 の AuthSession・SubjectCleanup・PreferenceRegistry テスト（ios-test-099・ios-test-100・ios-test-102）で共有する
// test double とヘルパー。spec.md §5.5「共通 double」を参照。
//
// - `NowPlayingCenterSpy` / `PlaybackLifecycleSpy`: SubjectCleanup が呼ぶ port の spy（呼出回数と、
//   呼ばれた時点の任意の追加観測を `onStopForLogout` / `onClear` フックで行える）。
// - `FailingRemoveFileManager`: `AudioCacheManagerTests.MockFileManager` を土台に、
//   `removeItem` だけ throw する「失敗版」（T-T15-03・04 用。§5.5 共通 double）。
// - `makeSubjectAwareAppState`: 主体離脱（logout・401 失効）を伴うテストで必ず doubles を注入する
//   ためのファクトリ（PM-8: 実機のキャッシュディレクトリ・`MPNowPlayingInfoCenter` に触れないため）。

// MARK: - Ports の spy（ios-contract-21.2, 15.6, 15.9）

/// `NowPlayingCenter` の spy。`clear()` の呼出回数（ios-slice-auth-01）に加えて、ios-slice-playback-01 で増えた操作の結果を
/// 状態として保持する（`currentInfo` / `lastElapsedUpdate` / 発行した token と handler の組）。
/// 呼出回数ではなく、観測できる状態でテストする。
final class NowPlayingCenterSpy: NowPlayingCenter {
    private(set) var clearCallCount = 0
    /// `clear()` が呼ばれた時点の追加観測用フック（例: token/session のスナップショット）。
    var onClear: (() -> Void)?

    /// ロック画面へ渡した値（`update` で設定し、`clear` で nil）。
    private(set) var currentInfo: NowPlayingSnapshot?
    /// 直近の `updateElapsed` の引数。
    private(set) var lastElapsedUpdate: (elapsed: Double, duration: Double)?
    /// `registerCommands` が発行した token と handler の組（発行順）。
    private(set) var registrations: [(token: RemoteCommandRegistration, handler: @MainActor (RemoteCommand) -> RemoteCommandResult)] = []

    /// 解除されていない（`isCancelled == false` の）token の数。
    var activeRegistrationCount: Int { registrations.filter { !$0.token.isCancelled }.count }

    func update(_ snapshot: NowPlayingSnapshot) {
        currentInfo = snapshot
    }

    func updateElapsed(_ elapsed: Double, duration: Double) {
        lastElapsedUpdate = (elapsed, duration)
    }

    func clear() {
        clearCallCount += 1
        currentInfo = nil
        onClear?()
    }

    func registerCommands(
        _ handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult
    ) -> RemoteCommandRegistration {
        let token = RemoteCommandRegistration(removal: {})
        registrations.append((token, handler))
        return token
    }

    func unregister(_ registration: RemoteCommandRegistration) {
        registration.cancel()
    }

    /// 有効な登録の handler へコマンドを渡す（ロック画面のコマンドを模す）。有効な登録が無ければ失敗させる。
    @MainActor
    func invoke(_ command: RemoteCommand, file: StaticString = #filePath, line: UInt = #line) -> RemoteCommandResult {
        guard let active = registrations.last(where: { !$0.token.isCancelled }) else {
            XCTFail("有効なリモートコマンド登録が無い", file: file, line: line)
            return .commandFailed
        }
        return active.handler(command)
    }
}

/// `PlaybackLifecycle.stopForLogout()` の呼出回数を記録する spy。
@MainActor
final class PlaybackLifecycleSpy: PlaybackLifecycle {
    private(set) var stopForLogoutCallCount = 0
    /// `stopForLogout()` が呼ばれた時点の追加観測用フック（例: token/session のスナップショット）。
    var onStopForLogout: (() -> Void)?

    func stopForLogout() {
        stopForLogoutCallCount += 1
        onStopForLogout?()
    }
}

// MARK: - FileManager 失敗版（ios-contract-21.3）

/// `AudioCacheManagerTests.MockFileManager` と同じインメモリ実装だが、`removeItem` だけ throw する。
/// `removeSubject` は主体ディレクトリへ `removeItem` を呼ぶため、これを注入すると
/// `AudioCacheManager.removeSubject(_:)` が必ず失敗する（SubjectCleanup の音声キャッシュ手順の失敗経路）。
final class FailingRemoveFileManager: FileManagerProtocol {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    struct RemoveFailure: Error {}

    func fileExists(atPath: String) -> Bool {
        let prefix = atPath + "/"
        return files[atPath] != nil || directories.contains(atPath)
            || files.keys.contains { $0.hasPrefix(prefix) }
            || directories.contains { $0.hasPrefix(prefix) }
    }

    func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        directories.insert(at.path)
    }

    func removeItem(at: URL) throws {
        throw RemoveFailure()
    }

    func write(_ data: Data, to: URL) throws {
        files[to.path] = data
    }

    func fileSize(atPath: String) -> Int64? {
        files[atPath]?.count.int64
    }

    func cachesDirectory() -> URL {
        URL(fileURLWithPath: "/mock-caches")
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var names: [String] = []
        for key in Array(files.keys) + Array(directories) where key.hasPrefix(prefix) {
            if let name = String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init),
               !names.contains(name) { names.append(name) }
        }
        return names
    }
}

// MARK: - 音声ライブラリの呼出記録（AppState の 3 つの closure の spy）

/// `AppState` が受ける `bindOfflineSubject`・`reclaimOfflineLibrary`・`clearOfflineLibrary` の呼出を、
/// 呼ばれた順に記録するテスト専用の spy。
@MainActor
final class OfflineLibraryCallLog {
    enum Event: Equatable {
        case bind(SubjectKey?)
        case reclaim(SubjectKey?)
        case clear(SubjectKey?)
    }

    private(set) var events: [Event] = []
    /// 設定すると `reclaim` の closure が throw する。
    var reclaimError: Error?
    /// `clear` の closure が呼ばれた時点の追加観測（token と session のスナップショット用）。
    var onClear: ((SubjectKey?) -> Void)?

    var lastBindEvent: Event? { events.last { if case .bind = $0 { return true } else { return false } } }
    var bindCalls: [SubjectKey?] { events.compactMap { (event) -> SubjectKey?? in if case .bind(let k) = event { return .some(k) } else { return nil } } }
    var reclaimCalls: [SubjectKey?] { events.compactMap { (event) -> SubjectKey?? in if case .reclaim(let k) = event { return .some(k) } else { return nil } } }
    var clearCalls: [SubjectKey?] { events.compactMap { (event) -> SubjectKey?? in if case .clear(let k) = event { return .some(k) } else { return nil } } }

    var bind: (SubjectKey?) -> Void {
        { [unowned self] key in self.events.append(.bind(key)) }
    }

    var reclaim: (SubjectKey?) throws -> Void {
        { [unowned self] key in
            self.events.append(.reclaim(key))
            if let error = self.reclaimError { throw error }
        }
    }

    var clear: (SubjectKey?) throws -> Void {
        { [unowned self] key in
            self.events.append(.clear(key))
            self.onClear?(key)
        }
    }
}

// MARK: - AppState ファクトリ（主体離脱を伴うテスト共通。PM-8）

/// 主体離脱（logout・401 失効）を伴うテストで使う `AppState` を、実機のキャッシュディレクトリや
/// `MPNowPlayingInfoCenter` に触れない doubles 一式（NowPlayingCenter spy・空のキャッシュを模す MockFileManager）で組み立てる。
/// - Parameters:
///   - session: `AppState` と設定の同期の通信に使う test double（未指定なら空応答の `MockURLSession`）。
///   - sessionStore: セッショントークンの保管（未指定ならインメモリ）。
///   - nowPlayingCenter: 未指定なら新規 `NowPlayingCenterSpy`。
///   - offlineFileManager: `AudioCacheManager` に注入する `FileManagerProtocol`
///     （未指定なら空の `AudioCacheManagerTests.MockFileManager`。失敗させたい場合は
///     `FailingRemoveFileManager` を渡す）。
///   - clearOfflineLibrary: 未指定なら離脱主体のディレクトリだけを `cache` から消す。
///   - bindOfflineSubject / reclaimOfflineLibrary: 未指定なら何もしない。
@MainActor
func makeSubjectAwareAppState(
    session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200),
    sessionStore: SessionStore = InMemorySessionStore(),
    nowPlayingCenter: NowPlayingCenterSpy = NowPlayingCenterSpy(),
    offlineFileManager: FileManagerProtocol = AudioCacheManagerTests.MockFileManager(),
    clearOfflineLibrary: ((SubjectKey?) throws -> Void)? = nil,
    bindOfflineSubject: @escaping (SubjectKey?) -> Void = { _ in },
    reclaimOfflineLibrary: @escaping (SubjectKey?) throws -> Void = { _ in }
) -> AppState {
    let cache = AudioCacheManager(fileManager: offlineFileManager)
    // 起動時の設定の同期（`LaunchSequence` → `GET /settings/preferences`）を本番と同じ配線で保つため、store を後結合で結ぶ。
    let wired = makeAppStateWithPreferences(
        session: session,
        sessionStore: sessionStore,
        nowPlayingCenter: nowPlayingCenter,
        clearOfflineLibrary: clearOfflineLibrary ?? { key in if let key { try cache.removeSubject(key) } },
        bindOfflineSubject: bindOfflineSubject,
        reclaimOfflineLibrary: reclaimOfflineLibrary
    )
    return wired.state
}

// MARK: - 合成 root と同じ配線の harness（ios-slice-closure-01）

/// 本番の合成 root（`NewsListenAppApp`）と同じ形で、`AppState`・`PreferencesStore`・`PushRegistration`・
/// `LaunchSequence` を後結合の箱（弱参照）で結ぶ。`AppState` は Account だけを持つので、設定の同期と
/// 端末トークンの登録は、ここで root と同じ closure を渡して組む。
/// - Important: `login(_:)` と `resolveAndLaunch()` の closure は、root の login の完了 closure と `.task` と同じ形に保つ。
@MainActor
final class AppStateHarness {
    let state: AppState
    let store: PreferencesStore
    let push: PushRegistration
    let launch: LaunchSequence
    private let makeCurrentClient: () -> APIClient?

    fileprivate init(
        state: AppState, store: PreferencesStore, push: PushRegistration, launch: LaunchSequence,
        currentClient: @escaping () -> APIClient?
    ) {
        self.state = state
        self.store = store
        self.push = push
        self.launch = launch
        self.makeCurrentClient = currentClient
    }

    /// 呼ぶたびに、その時点の保存トークンで作る client。401 は `sessionExpiryObserver` に届く（本番の `makeClient` と同じ形）。
    func currentClient() -> APIClient? { makeCurrentClient() }

    /// root の `.task` と同じ配線。`resolve()` が true のときだけ、非構造化 Task で `run()` を起こし、その Task を返す。
    func resolveAndLaunch() async -> Task<Void, Never>? {
        guard await state.resolve() else { return nil }
        return Task { await launch.run() }
    }

    /// root の login の完了 closure と同じ形。登録の予約だけをして、設定の同期はしない。
    func login(_ receipt: LoginReceipt) {
        state.completeLogin(receipt)
        Task { await push.registerIfPossible() }
    }
}

/// `makeAppStateWithPreferences` と同じ引数で `AppStateHarness` を組む。
@MainActor
func makeAppStateHarness(
    session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200),
    sessionStore: SessionStore = InMemorySessionStore(),
    defaults: UserDefaults = UserDefaults(suiteName: "AppStateTestSupport.\(UUID().uuidString)")!,
    nowPlayingCenter: NowPlayingCenterSpy = NowPlayingCenterSpy(),
    clearOfflineLibrary: ((SubjectKey?) throws -> Void)? = nil,
    bindOfflineSubject: @escaping (SubjectKey?) -> Void = { _ in },
    reclaimOfflineLibrary: @escaping (SubjectKey?) throws -> Void = { _ in },
    gatewayOverride: PreferencesGateway? = nil
) -> AppStateHarness {
    final class Box { weak var state: AppState? }
    let box = Box()
    func makeClient(token: String?, onUnauthorized: @escaping @MainActor () -> Void) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token,
            session: session, onUnauthorized: onUnauthorized)
    }
    let currentClient: () -> APIClient? = {
        let token = sessionStore.token
        return makeClient(token: token, onUnauthorized: box.state?.sessionExpiryObserver(sentToken: token) ?? {})
    }
    let store = PreferencesStore(
        gateway: gatewayOverride ?? .live(client: currentClient),
        storage: .live(registry: PreferenceRegistry(defaults: defaults)),
        isCurrentSubject: { box.state?.isCurrentSubject($0) ?? false },
        subjectStamp: { box.state!.subjectStamp },
        isAuthenticated: { box.state?.currentSubject != nil }
    )
    let push = PushRegistration(
        gateway: { currentClient().map { PushGateway.live(apiClient: $0) } },
        isAuthenticated: { box.state?.currentSubject != nil },
        subjectStamp: { box.state!.subjectStamp },
        isCurrentSubject: { box.state?.isCurrentSubject($0) ?? false }
    )
    let launch = LaunchSequence(
        refreshPreferences: { await store.refreshFromServer() },
        registerPush: { await push.registerIfPossible() },
        subjectStamp: { box.state!.subjectStamp },
        isCurrentSubject: { box.state?.isCurrentSubject($0) ?? false }
    )
    let state = AppState(
        sessionStore: sessionStore,
        accountGatewayFactory: { token, onUnauthorized in
            AccountGateway.live(apiClient: makeClient(token: token, onUnauthorized: onUnauthorized))
        },
        isConfigured: true,
        clearSubjectPreferences: { store.clearSubjectScoped() },
        nowPlayingCenter: nowPlayingCenter,
        clearOfflineLibrary: clearOfflineLibrary ?? { _ in },
        bindOfflineSubject: bindOfflineSubject,
        reclaimOfflineLibrary: reclaimOfflineLibrary,
        cancelPushRegistration: { push.cancelPendingRegistration() }
    )
    box.state = state
    return AppStateHarness(state: state, store: store, push: push, launch: launch, currentClient: currentClient)
}

/// `ScriptedURLSession` に、`method` + `path` の request が `count` 件届くまで MainActor を明け渡して待つ。
/// 届かなければ（実装の欠陥で）止まらないよう、上限の後に抜ける。呼出元が件数を assert する。
@MainActor
func waitForRequests(
    _ session: ScriptedURLSession, method: String, path: String, count: Int = 1, maxYields: Int = 500
) async {
    for _ in 0..<maxYields {
        let seen = session.sentRequests.filter { $0.httpMethod == method && $0.url?.path == path }.count
        if seen >= count { return }
        await Task.yield()
    }
}

// MARK: - AppState と PreferencesStore を本番と同じ後結合で結ぶファクトリ（ios-dec-92）

/// `AppState` と `PreferencesStore` を、本番の合成 root と同じ後結合の箱（弱参照）で結ぶ（実体は `makeAppStateHarness`）。
/// `accountGatewayFactory` を必ず渡すので、`AppState` が Info.plist の `APIBaseURL` へ落ちる経路は無い。
/// - Parameters:
///   - session: gateway・`AppState` の通信に使う test double（未指定なら空応答 200 の `MockURLSession`）。
///   - defaults: store の保存先 `PreferenceRegistry(defaults:)` の `UserDefaults`。
///   - gatewayOverride: 指定すると `PreferencesGateway.live(client:)` の代わりに使う。
/// - Returns: 戻り値の `state` をテストが保持するので、箱の弱参照は外れない。
@MainActor
func makeAppStateWithPreferences(
    session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200),
    sessionStore: SessionStore = InMemorySessionStore(),
    defaults: UserDefaults = UserDefaults(suiteName: "AppStateTestSupport.\(UUID().uuidString)")!,
    nowPlayingCenter: NowPlayingCenterSpy = NowPlayingCenterSpy(),
    clearOfflineLibrary: ((SubjectKey?) throws -> Void)? = nil,
    bindOfflineSubject: @escaping (SubjectKey?) -> Void = { _ in },
    reclaimOfflineLibrary: @escaping (SubjectKey?) throws -> Void = { _ in },
    gatewayOverride: PreferencesGateway? = nil
) -> (state: AppState, store: PreferencesStore) {
    let harness = makeAppStateHarness(
        session: session, sessionStore: sessionStore, defaults: defaults, nowPlayingCenter: nowPlayingCenter,
        clearOfflineLibrary: clearOfflineLibrary, bindOfflineSubject: bindOfflineSubject,
        reclaimOfflineLibrary: reclaimOfflineLibrary, gatewayOverride: gatewayOverride)
    return (harness.state, harness.store)
}
