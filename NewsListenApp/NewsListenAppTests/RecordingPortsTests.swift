import XCTest
import Combine
@testable import NewsListenApp

/// 書込み port の記録 double（`RecordingPorts`）の自己検査と、query が書込み port へ漏らす 3 経路の負の fixture。
/// 数えるのは書込みだけで、同じ値の書き戻しも数える。
@MainActor
final class RecordingPortsTests: XCTestCase {

    private var ports: RecordingPorts!

    override func setUp() async throws {
        try await super.setUp()
        ports = RecordingPorts()
    }

    override func tearDown() async throws {
        ports.removeSuite()
        ports = nil
        try await super.tearDown()
    }

    private func request(_ method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        request.httpMethod = method
        return request
    }

    private struct ThrowingURLSession: URLSessionProtocol {
        struct Failure: Error {}
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw Failure() }
    }

    // MARK: - 各 double の自己検査

    func testUserDefaultsCountsEveryWriteIncludingSameValueAndIgnoresReads() {
        let defaults = ports.userDefaults
        defaults.set("a", forKey: "k")
        XCTAssertEqual(defaults.writeCount, 1)
        defaults.set("a", forKey: "k")
        XCTAssertEqual(defaults.writeCount, 2, "同じ値の書き戻しも数える")
        _ = defaults.object(forKey: "k")
        XCTAssertEqual(defaults.writeCount, 2, "読みは数えない")
        defaults.removeObject(forKey: "k")
        XCTAssertEqual(defaults.writeCount, 3)
    }

    func testUserDefaultsCountsEachTypedSetExactlyOnce() {
        let defaults = ports.userDefaults
        let integer: Int = 3
        let double: Double = 1.5
        let float: Float = 1.5
        let writes: [(label: String, perform: () -> Void)] = [
            ("Bool", { defaults.set(true, forKey: "b") }),
            ("Int", { defaults.set(integer, forKey: "i") }),
            ("Double", { defaults.set(double, forKey: "d") }),
            ("Float", { defaults.set(float, forKey: "f") }),
            ("URL", { defaults.set(URL(string: "https://example.com"), forKey: "u") }),
        ]
        for write in writes {
            defaults.resetCounts()
            write.perform()
            XCTAssertEqual(defaults.writeCount, 1, "型付きの set は 1 回の呼出を 1 と数える（二重に数えない）: \(write.label)")
        }
    }

    func testUserDefaultsCountsWriteThroughPreferenceRegistry() {
        let registry = PreferenceRegistry(defaults: ports.userDefaults)
        registry.set(registry.sfxEnabled, true)
        XCTAssertEqual(ports.userDefaults.writeCount, 1, "実際の書込み経路（PreferenceRegistry.set）に override が当たる")
    }

    func testSessionStoreCountsTokenSetterIncludingNilAndIgnoresReads() {
        let store = ports.sessionStore
        store.token = "t"
        XCTAssertEqual(store.writeCount, 1)
        store.token = "t"
        XCTAssertEqual(store.writeCount, 2, "同じ値の書き戻しも数える")
        _ = store.token
        XCTAssertEqual(store.writeCount, 2, "読みは数えない")
        store.token = nil
        XCTAssertEqual(store.writeCount, 3, "nil の代入も数える")
        XCTAssertNil(store.token, "委譲先の挙動（保存）は変えない")
    }

    func testURLSessionCountsWriteVerbsOnly() async throws {
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            _ = try await ports.urlSession.data(for: request(method))
        }
        XCTAssertEqual(ports.urlSession.writeCount, 4)
        _ = try await ports.urlSession.data(for: request("GET"))
        XCTAssertEqual(ports.urlSession.writeCount, 4, "GET は数えない")
    }

    func testURLSessionCountsWriteEvenWhenDelegateThrows() async {
        let throwing = RecordingPorts(urlSessionDelegate: ThrowingURLSession())
        defer { throwing.removeSuite() }
        do {
            _ = try await throwing.urlSession.data(for: request("POST"))
            XCTFail("委譲先の throw が伝わらない")
        } catch {
            XCTAssertEqual(throwing.urlSession.writeCount, 1, "委譲の前に数えるので、throw しても数えた 1 は残る")
        }
    }

    func testFileManagerCountsWriteRemoveAndCreateDirectory() throws {
        let manager = ports.fileManager
        let url = URL(fileURLWithPath: "/mock-caches/x.bin")
        try manager.write(Data([1]), to: url)
        XCTAssertEqual(manager.writeCount, 1)
        try manager.removeItem(at: url)
        XCTAssertEqual(manager.writeCount, 2)
        try manager.createDirectory(at: URL(fileURLWithPath: "/mock-caches/d"), withIntermediateDirectories: true, attributes: nil)
        XCTAssertEqual(manager.writeCount, 3)
    }

    func testFileManagerCountsSameValueRewriteAndIgnoresReads() throws {
        let manager = ports.fileManager
        let url = URL(fileURLWithPath: "/mock-caches/x.bin")
        try manager.write(Data([1]), to: url)
        try manager.write(Data([1]), to: url)
        XCTAssertEqual(manager.writeCount, 2, "同じ値の書き戻しも数える")
        _ = manager.fileExists(atPath: url.path)
        _ = manager.fileSize(atPath: url.path)
        _ = manager.cachesDirectory()
        _ = try manager.contentsOfDirectory(atPath: "/mock-caches")
        XCTAssertEqual(manager.writeCount, 2, "読みは数えない")
        XCTAssertTrue(manager.fileExists(atPath: url.path), "委譲先の挙動（保存）は変えない")
    }

    func testClearOfflineLibraryCountsEveryRun() throws {
        try ports.clearOfflineLibrary.run()
        XCTAssertEqual(ports.clearOfflineLibrary.writeCount, 1)
        try ports.clearOfflineLibrary.run()
        XCTAssertEqual(ports.clearOfflineLibrary.writeCount, 2, "同じ状態への再実行も数える")
    }

    func testClearOfflineLibraryCountsEvenWhenDelegateThrows() {
        let failing = FailingRemoveFileManager()
        failing.files["/mock-caches/NewsListenApp/audio-cache/x.mp3"] = Data([1])
        let throwing = RecordingPorts(fileManagerDelegate: failing)
        defer { throwing.removeSuite() }

        XCTAssertThrowsError(try throwing.clearOfflineLibrary.run())

        XCTAssertEqual(throwing.clearOfflineLibrary.writeCount, 1, "委譲の前に数えるので、throw しても数えた 1 は残る")
    }

    func testTotalWritesSumsAllFiveDoublesAndResetClearsThem() async throws {
        ports.userDefaults.set("a", forKey: "k")
        ports.sessionStore.token = "t"
        _ = try await ports.urlSession.data(for: request("POST"))
        try ports.fileManager.write(Data([1]), to: URL(fileURLWithPath: "/mock-caches/x.bin"))
        try ports.clearOfflineLibrary.run()
        XCTAssertEqual(ports.totalWrites, 5, "5 つの double に 1 回ずつ書いた合計")

        ports.resetCounts()
        XCTAssertEqual(ports.totalWrites, 0)
    }

    // MARK: - query が書込み port に漏れる経路（負の fixture）

    /// (b) getter の中で `PreferenceRegistry.set` を呼び、今の値を書き戻す query。
    private final class LeakyPreferenceQuery {
        private let registry: PreferenceRegistry

        init(registry: PreferenceRegistry) { self.registry = registry }

        var difficulty: String {
            let current = registry.get(registry.defaultDifficulty)
            registry.set(registry.defaultDifficulty, current)
            return current
        }
    }

    /// (c) 取得を `await` した後に、書込みの request を送る query。
    private final class LeakyAsyncQuery {
        private let client: APIClient

        init(client: APIClient) { self.client = client }

        func load() async {
            _ = try? await client.fetchOnboardingStatus()
            await Task.yield()
            _ = try? await client.completeOnboarding()
        }
    }

    /// (d) Combine の購読の発火で `FileManagerProtocol.write` を呼ぶ query。
    private final class LeakySubscriptionQuery {
        let subject = PassthroughSubject<Int, Never>()
        private var cancellable: AnyCancellable?

        init(fileManager: FileManagerProtocol) {
            cancellable = subject.sink { _ in
                try? fileManager.write(Data([1]), to: URL(fileURLWithPath: "/mock-caches/leak.bin"))
            }
        }
    }

    /// 読むだけの query（対照）。
    private final class ReadOnlyQuery {
        private let registry: PreferenceRegistry
        private let client: APIClient
        let subject = PassthroughSubject<Int, Never>()
        private var cancellable: AnyCancellable?
        private(set) var received = 0

        init(registry: PreferenceRegistry, client: APIClient) {
            self.registry = registry
            self.client = client
            cancellable = subject.sink { [weak self] value in self?.received = value }
        }

        var difficulty: String { registry.get(registry.defaultDifficulty) }

        func load() async {
            _ = try? await client.fetchOnboardingStatus()
        }
    }

    private func makeClient() -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: ports.urlSession)
    }

    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    func testQueryThatRewritesPreferenceInGetterIsCounted() async {
        let query = LeakyPreferenceQuery(registry: PreferenceRegistry(defaults: ports.userDefaults))
        ports.resetCounts()

        _ = query.difficulty
        await settle()

        XCTAssertGreaterThanOrEqual(ports.totalWrites, 1, "getter の中の書き戻しが数えられる")
    }

    func testQueryThatPostsAfterAwaitIsCounted() async {
        let query = LeakyAsyncQuery(client: makeClient())
        ports.resetCounts()

        await query.load()
        await settle()

        XCTAssertGreaterThanOrEqual(ports.totalWrites, 1, "await の後に送る POST が数えられる")
    }

    func testQueryThatWritesFileOnSubscriptionFireIsCounted() async {
        let query = LeakySubscriptionQuery(fileManager: ports.fileManager)
        ports.resetCounts()

        query.subject.send(1)
        await settle()

        XCTAssertGreaterThanOrEqual(ports.totalWrites, 1, "購読の発火で書く write が数えられる")
    }

    func testReadOnlyQueryWritesNothingAcrossReadAwaitAndFire() async {
        let query = ReadOnlyQuery(registry: PreferenceRegistry(defaults: ports.userDefaults), client: makeClient())
        ports.resetCounts()

        _ = query.difficulty
        await query.load()
        query.subject.send(1)
        await settle()

        XCTAssertEqual(query.received, 1, "購読が実際に発火している")
        XCTAssertEqual(ports.totalWrites, 0, "読むだけの query は書込み 0")
    }
}
