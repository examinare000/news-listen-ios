import XCTest
@testable import NewsListenApp

// I-S2 の AuthSession・SubjectCleanup・PreferenceRegistry テスト（T-T14・T-T15・T-T17）で共有する
// test double とヘルパー。spec.md §5.5「共通 double」を参照。
//
// - `NowPlayingCenterSpy` / `PlaybackLifecycleSpy`: SubjectCleanup が呼ぶ port の spy（呼出回数と、
//   呼ばれた時点の任意の追加観測を `onStopForLogout` / `onClear` フックで行える）。
// - `FailingRemoveFileManager`: `AudioCacheManagerTests.MockFileManager` を土台に、
//   `removeItem` だけ throw する「失敗版」（T-T15-03・04 用。§5.5 共通 double）。
// - `makeSubjectAwareAppState`: 主体離脱（logout・401 失効）を伴うテストで必ず doubles を注入する
//   ためのファクトリ（PM-8: 実機のキャッシュディレクトリ・`MPNowPlayingInfoCenter` に触れないため）。

// MARK: - Ports の spy（CI-T15.2, 15.6, 15.9）

/// `NowPlayingCenter` の spy。`clear()` の呼出回数（I-S2）に加えて、I-S3a で増えた操作の結果を
/// 状態として保持する（`currentInfo` / `lastElapsedUpdate` / 発行した token と handler の組）。
/// 呼出回数ではなく、観測できる状態でテストする。
final class NowPlayingCenterSpy: NowPlayingCenter {
    private(set) var clearCallCount = 0
    /// `clear()` が呼ばれた時点の追加観測用フック（例: token/session のスナップショット）。
    var onClear: (() -> Void)?

    /// ロック画面の辞書（`update` で設定し、`clear` で nil）。
    private(set) var currentInfo: [String: Any]?
    /// 直近の `updateElapsed` の引数。
    private(set) var lastElapsedUpdate: (elapsed: Double, duration: Double)?
    /// `registerCommands` が発行した token と handler の組（発行順）。
    private(set) var registrations: [(token: RemoteCommandRegistration, handler: @MainActor (RemoteCommand) -> RemoteCommandResult)] = []

    /// 解除されていない（`isCancelled == false` の）token の数。
    var activeRegistrationCount: Int { registrations.filter { !$0.token.isCancelled }.count }

    func update(_ info: [String: Any]) {
        currentInfo = info
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

// MARK: - FileManager 失敗版（CI-T15.3）

/// `AudioCacheManagerTests.MockFileManager` と同じインメモリ実装だが、`removeItem` だけ throw する。
/// `clearCache()` はディレクトリ内の各ファイルへ `removeItem` を呼ぶため、これを注入すると
/// `AudioCacheManager.clearCache()` が必ず失敗する（SubjectCleanup の音声キャッシュ手順の失敗経路）。
final class FailingRemoveFileManager: FileManagerProtocol {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    struct RemoveFailure: Error {}

    func fileExists(atPath: String) -> Bool {
        files[atPath] != nil || directories.contains(atPath)
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
        return files.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let name = String(key.dropFirst(prefix.count))
            return name.contains("/") ? nil : name
        }
    }
}

// MARK: - AppState ファクトリ（主体離脱を伴うテスト共通。PM-8）

/// 主体離脱（logout・401 失効）を伴うテストで使う `AppState` を、実機のキャッシュディレクトリや
/// `MPNowPlayingInfoCenter` に触れない doubles 一式（NowPlayingCenter spy・UUID suite の
/// PreferenceRegistry・空のキャッシュを模す MockFileManager）で組み立てる。
/// - Parameters:
///   - session: `apiClient`/`apiClientFactory` の通信に使う test double（未指定なら空応答の `MockURLSession`）。
///   - sessionStore: セッショントークンの保管（未指定ならインメモリ）。
///   - nowPlayingCenter: 未指定なら新規 `NowPlayingCenterSpy`。
///   - offlineFileManager: `AudioCacheManager` に注入する `FileManagerProtocol`
///     （未指定なら空の `AudioCacheManagerTests.MockFileManager`。失敗させたい場合は
///     `FailingRemoveFileManager` を渡す）。
@MainActor
func makeSubjectAwareAppState(
    session: URLSessionProtocol = MockURLSession(data: Data("{}".utf8), statusCode: 200),
    sessionStore: SessionStore = InMemorySessionStore(),
    nowPlayingCenter: NowPlayingCenterSpy = NowPlayingCenterSpy(),
    offlineFileManager: FileManagerProtocol = AudioCacheManagerTests.MockFileManager()
) -> AppState {
    let suiteName = "AppStateTestSupport.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    let cache = AudioCacheManager(fileManager: offlineFileManager)
    return AppState(
        sessionStore: sessionStore,
        apiClientFactory: { token, onUnauthorized in
            APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
        },
        preferences: PreferenceRegistry(defaults: suite),
        nowPlayingCenter: nowPlayingCenter,
        clearOfflineLibrary: { try cache.clearCache() }
    )
}
