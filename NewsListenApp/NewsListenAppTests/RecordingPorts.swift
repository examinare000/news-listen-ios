import Foundation
import os
@testable import NewsListenApp

// 書込み port の記録 double（ios-check-15 (b)・ios-check-09）。production の既存の継ぎ目に被せる。
// production に新しい protocol を足さず、test target に目標名の protocol も置かない。
// 同じ値を書き戻す呼出も数える。読みは数えない。

/// スレッドをまたいで書込みの回数を数える。
final class WriteCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    var count: Int { lock.withLock { $0 } }

    func increment() {
        lock.withLock { $0 += 1 }
    }

    func reset() {
        lock.withLock { $0 = 0 }
    }

    /// 書込みの外側の 1 回だけを数える。override の中から別の override が呼ばれても二重に数えない。
    /// 入れ子の深さは呼出元のスレッドごとに持つ。
    func countOutermost(_ body: () throws -> Void) rethrows {
        let key = "WriteCounter.depth.\(ObjectIdentifier(self).hashValue)"
        let dictionary = Thread.current.threadDictionary
        let depth = dictionary[key] as? Int ?? 0
        if depth == 0 { increment() }
        dictionary[key] = depth + 1
        defer { dictionary[key] = depth == 0 ? nil : depth }
        try body()
    }
}

/// `PreferenceRegistry(defaults:)` に渡す `UserDefaults`。書込み系の overload と `removeObject(forKey:)` を数える。
final class RecordingUserDefaults: UserDefaults {
    private let counter = WriteCounter()

    var writeCount: Int { counter.count }

    func resetCounts() { counter.reset() }

    override func set(_ value: Any?, forKey defaultName: String) {
        counter.countOutermost { super.set(value, forKey: defaultName) }
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        counter.countOutermost { super.set(value, forKey: defaultName) }
    }

    override func set(_ value: Int, forKey defaultName: String) {
        counter.countOutermost { super.set(value, forKey: defaultName) }
    }

    override func set(_ value: Double, forKey defaultName: String) {
        counter.countOutermost { super.set(value, forKey: defaultName) }
    }

    override func set(_ value: Float, forKey defaultName: String) {
        counter.countOutermost { super.set(value, forKey: defaultName) }
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        counter.countOutermost { super.set(url, forKey: defaultName) }
    }

    override func removeObject(forKey defaultName: String) {
        counter.countOutermost { super.removeObject(forKey: defaultName) }
    }
}

/// `AppState.init(sessionStore:)` に渡す `SessionStore`。`token` の setter（`nil` の代入を含む）を数える。
final class RecordingSessionStore: SessionStore {
    private let counter = WriteCounter()
    private var storedToken: String?

    init(token: String? = nil) {
        storedToken = token
    }

    var token: String? {
        get { storedToken }
        set {
            counter.increment()
            storedToken = newValue
        }
    }

    var writeCount: Int { counter.count }

    func resetCounts() { counter.reset() }
}

/// `APIClient(session:)` に渡す `URLSessionProtocol`。POST・PUT・PATCH・DELETE の request を数える（GET は数えない）。
final class RecordingURLSession: URLSessionProtocol, @unchecked Sendable {
    private let delegate: URLSessionProtocol
    private let counter = WriteCounter()
    private static let writeMethods: Set<String> = ["POST", "PUT", "PATCH", "DELETE"]

    init(delegate: URLSessionProtocol = ScriptedURLSession()) {
        self.delegate = delegate
    }

    var writeCount: Int { counter.count }

    func resetCounts() { counter.reset() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if Self.writeMethods.contains(request.httpMethod?.uppercased() ?? "GET") { counter.increment() }
        return try await delegate.data(for: request)
    }
}

/// `AudioCacheManager(fileManager:)` に渡す `FileManagerProtocol`。`write(_:to:)`・`removeItem(at:)`・`createDirectory` を数える。
final class RecordingFileManager: FileManagerProtocol {
    private let delegate: FileManagerProtocol
    private let counter = WriteCounter()

    init(delegate: FileManagerProtocol = AudioCacheManagerTests.MockFileManager()) {
        self.delegate = delegate
    }

    var writeCount: Int { counter.count }

    func resetCounts() { counter.reset() }

    func fileExists(atPath path: String) -> Bool {
        delegate.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        counter.increment()
        try delegate.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }

    func removeItem(at url: URL) throws {
        counter.increment()
        try delegate.removeItem(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        counter.increment()
        try delegate.write(data, to: url)
    }

    func fileSize(atPath path: String) -> Int64? {
        delegate.fileSize(atPath: path)
    }

    func cachesDirectory() -> URL {
        delegate.cachesDirectory()
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        try delegate.contentsOfDirectory(atPath: path)
    }
}

/// `AppState.init(clearOfflineLibrary:)` に `{ key in try recorder.run(subject: key) }` として渡す。`run(subject:)` の呼出を数え、
/// 主体が非 nil なら `AudioCacheManager.removeSubject(_:)` へ委譲する。
final class RecordingClearOfflineLibrary {
    private let cache: AudioCacheManager
    private let counter = WriteCounter()

    init(cache: AudioCacheManager) {
        self.cache = cache
    }

    var writeCount: Int { counter.count }

    func resetCounts() { counter.reset() }

    func run(subject: SubjectKey?) throws {
        counter.increment()
        if let subject { try cache.removeSubject(subject) }
    }
}

/// 再生の gateway（`PositionReporter` の `updatePosition`・`markCompleted`、`PlaybackCoordinator` の `fetchEpisode`）の記録 double。
/// `updatePosition`・`markCompleted` は呼ばれるたびに数える（同値も数える）。`fetchEpisode` は読みなので数えない。
/// `RecordingPorts` の struct（`AppState` の継ぎ目の束）には入れない。
final class RecordingPlaybackGateway {
    private let response: (String) -> Episode
    private let counter = WriteCounter()

    init(response: @escaping (String) -> Episode) {
        self.response = response
    }

    var writeCount: Int { counter.count }

    func resetCounts() { counter.reset() }

    var updatePosition: (String, Double) async throws -> Episode {
        { [self] id, _ in
            counter.increment()
            return response(id)
        }
    }

    var markCompleted: (String) async throws -> Void {
        { [self] _ in counter.increment() }
    }

    var fetchEpisode: (String) async throws -> Episode {
        { [self] id in response(id) }
    }
}

/// 5 つの double を既存の継ぎ目に合わせて束ねる。
struct RecordingPorts {
    /// ios-check-15 (b) の静的検査が、テストファイルの参照を数えるときに使う型名。
    static let doubleTypeNames: Set<String> = [
        "RecordingUserDefaults",
        "RecordingSessionStore",
        "RecordingURLSession",
        "RecordingFileManager",
        "RecordingClearOfflineLibrary",
        "RecordingPlaybackGateway",
    ]

    let suiteName: String
    let userDefaults: RecordingUserDefaults
    let sessionStore: RecordingSessionStore
    let urlSession: RecordingURLSession
    let fileManager: RecordingFileManager
    let clearOfflineLibrary: RecordingClearOfflineLibrary

    init(
        sessionToken: String? = nil,
        urlSessionDelegate: URLSessionProtocol = ScriptedURLSession(),
        fileManagerDelegate: FileManagerProtocol = AudioCacheManagerTests.MockFileManager()
    ) {
        suiteName = "RecordingPorts.\(UUID().uuidString)"
        userDefaults = RecordingUserDefaults(suiteName: suiteName)!
        sessionStore = RecordingSessionStore(token: sessionToken)
        urlSession = RecordingURLSession(delegate: urlSessionDelegate)
        fileManager = RecordingFileManager(delegate: fileManagerDelegate)
        clearOfflineLibrary = RecordingClearOfflineLibrary(cache: AudioCacheManager(fileManager: fileManager))
    }

    /// 5 つの double の書込みの合計。
    var totalWrites: Int {
        userDefaults.writeCount + sessionStore.writeCount + urlSession.writeCount
            + fileManager.writeCount + clearOfflineLibrary.writeCount
    }

    func resetCounts() {
        userDefaults.resetCounts()
        sessionStore.resetCounts()
        urlSession.resetCounts()
        fileManager.resetCounts()
        clearOfflineLibrary.resetCounts()
    }

    /// 使い終えた UUID の suite を消す。
    func removeSuite() {
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}
