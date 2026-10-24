// verifies: ios-cmd-playback-18, ios-cmd-playback-19, ios-cmd-playback-20, ios-query-playback-04
import XCTest
import Combine
@testable import NewsListenApp

/// `OfflineDownloads`（ダウンロードの手順・二重実行の抑止・cancel・`downloadingIds`）の契約テスト。
///
/// 保存庫は `AudioCacheManagerTests.MockFileManager` 越しの `AudioCacheManager` に `AudioFileStore.live` を被せて使う
/// （`PodcastViewModelTests.swift` にも同名の double があるので取り違えない）。
/// 取得の保留は continuation で行い、cancel を見ない（解放されたら `Data` を返す）。これで
/// `downloadAudio` の後の cancel 確認を外すと `save` が走って RED になる。
/// 同期点は `Task.yield()` の回数ではなく、保留に「入った」ことの明示的な待ちで取る。
/// テストの id は `AudioCacheManager` の id 検査（`[A-Za-z0-9_-]`、空でない）を通る文字だけを使う。

// MARK: - Doubles

private func playableEpisode(_ id: String, audioUrl: String = "https://cdn.example.com/a.mp3") throws -> Episode {
    guard let playable = PlayableEpisode(content: episodeContent(id), audioUrl: audioUrl, serverPosition: 0) else {
        throw FixtureError.invalid
    }
    return .playable(playable)
}

private func episodeContent(_ id: String) -> EpisodeContent {
    EpisodeContent(
        id: id, title: "題 \(id)", japaneseIntroText: "導入", difficulty: "toeic_900",
        createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
        segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
    )
}

private enum FixtureError: Error { case invalid }

/// テスト側の任意の Error 型（`DownloadFailure` でも `ApiFailure` でもない）。
private struct OddFailure: Error, Equatable {}

/// `write` だけが失敗する `FileManagerProtocol`（保存の失敗）。
private final class FailingWriteFileManager: FileManagerProtocol {
    struct WriteFailure: Error {}
    var files: [String: Data] = [:]
    var directories: Set<String> = []

    func fileExists(atPath: String) -> Bool { files[atPath] != nil || directories.contains(atPath) }
    func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        directories.insert(at.path)
    }
    func removeItem(at: URL) throws { files.removeValue(forKey: at.path) }
    func write(_ data: Data, to: URL) throws { throw WriteFailure() }
    func fileSize(atPath: String) -> Int64? { files[atPath]?.count.int64 }
    func cachesDirectory() -> URL { URL(fileURLWithPath: "/mock-caches") }
    func contentsOfDirectory(atPath path: String) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let name = String(key.dropFirst(prefix.count))
            return name.contains("/") ? nil : name
        }
    }
}

/// 取り直しと取得の double。呼出を記録し、取得は保留できる。保留は cancel を見ない。
@MainActor
private final class GatewayDouble {
    private(set) var fetchedIds: [String] = []
    private(set) var downloadedURLs: [URL] = []
    var onFetch: (String) throws -> Episode = { try playableEpisode($0) }
    var onDownload: (URL) throws -> Data = { _ in Data([1, 2, 3]) }
    var holdsDownloads = false

    private var held: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private var enterWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var released = false

    var pendingCount: Int { held.count }

    func fetch(_ id: String) async throws -> Episode {
        fetchedIds.append(id)
        return try onFetch(id)
    }

    func download(_ url: URL) async throws -> Data {
        downloadedURLs.append(url)
        if holdsDownloads && !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                held.append(continuation)
                entered += 1
                let ready = enterWaiters.filter { entered >= $0.count }
                enterWaiters.removeAll { entered >= $0.count }
                ready.forEach { $0.continuation.resume() }
            }
        }
        return try onDownload(url)
    }

    /// 保留に `count` 件が入るまで待つ。
    func waitUntilEntered(_ count: Int) async {
        if entered >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enterWaiters.append((count, continuation))
        }
    }

    /// 保留を全部解放する。以後の取得は保留せずに返す。
    func releaseAll() {
        released = true
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }
}

// MARK: - Tests

@MainActor
final class OfflineDownloadsTests: XCTestCase {

    private func makeLibrary(
        fileManager: FileManagerProtocol = AudioCacheManagerTests.MockFileManager()
    ) -> (library: OfflineLibrary, cache: AudioCacheManager) {
        let cache = AudioCacheManager(fileManager: fileManager)
        return (OfflineLibrary(store: .live(cacheManager: cache)), cache)
    }

    private func makeDownloads(
        library: OfflineLibrary, gateway: GatewayDouble
    ) -> OfflineDownloads {
        OfflineDownloads(
            library: library,
            fetchEpisode: { id in try await gateway.fetch(id) },
            downloadAudio: { url in try await gateway.download(url) }
        )
    }

    /// `download` を呼んで、投げられた error を返す（投げなければ失敗させる）。
    private func thrownError(
        by downloads: OfflineDownloads, id: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> Error? {
        do {
            let receipt = try await downloads.download(episodeId: id)
            XCTFail("投げるはずが \(receipt) を返した", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: ios-test-015 ios-cmd-playback-18 / ios-rule-playback-08

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (a)）
    func testT015_downloadSavesAfterFetchingAndDownloadingTheFreshUrl() async throws {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        let downloads = makeDownloads(library: library, gateway: gateway)

        let receipt: DownloadReceipt = try await downloads.download(episodeId: "a")

        XCTAssertEqual(receipt, .saved)
        XCTAssertEqual(gateway.fetchedIds, ["a"], "取り直しは 1 回")
        XCTAssertEqual(gateway.downloadedURLs, [URL(string: "https://cdn.example.com/a.mp3")], "取り直した URL で取得 1 回")
        XCTAssertTrue(library.has("a"))
        XCTAssertTrue(library.savedIds.contains("a"))
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (b)）
    func testT015_downloadOfSavedIdReturnsAlreadySavedWithoutCalling() async throws {
        let (library, _) = makeLibrary()
        try library.save(Data([1]), for: "a")
        let gateway = GatewayDouble()
        let downloads = makeDownloads(library: library, gateway: gateway)

        let receipt: DownloadReceipt = try await downloads.download(episodeId: "a")

        XCTAssertEqual(receipt, .alreadySaved)
        XCTAssertTrue(gateway.fetchedIds.isEmpty)
        XCTAssertTrue(gateway.downloadedURLs.isEmpty)
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (c)）
    func testT015_downloadWhileRunningReturnsAlreadyRunningAndFetchesOnce() async throws {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.holdsDownloads = true
        let downloads = makeDownloads(library: library, gateway: gateway)
        let first = Task { try await downloads.download(episodeId: "a") }
        await gateway.waitUntilEntered(1)

        let second: DownloadReceipt = try await downloads.download(episodeId: "a")

        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(gateway.fetchedIds, ["a"], "fetch は合計 1 回")
        gateway.releaseAll()
        let firstReceipt = try await first.value
        XCTAssertEqual(firstReceipt, .saved)
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (c)。await せずに同時に始める）
    // kills: downloadingIds.insert / tasks[id] の登録を最初の中断点より後（Task の中）に置く
    func testT015_twoConcurrentDownloadsStartedWithoutAwaitRunOnce() async throws {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.holdsDownloads = true
        let downloads = makeDownloads(library: library, gateway: gateway)

        let t1 = Task { try await downloads.download(episodeId: "a") }
        let t2 = Task { try await downloads.download(episodeId: "a") }
        await gateway.waitUntilEntered(1)
        for _ in 0..<5 { await Task.yield() }  // 二重実行する実装なら 2 本目の取得もここまでに保留へ入る
        gateway.releaseAll()
        let receipts = [try await t1.value, try await t2.value]

        XCTAssertEqual(receipts.filter { $0 == .saved }.count, 1, "片方だけが保存する")
        XCTAssertEqual(receipts.filter { $0 == .alreadyRunning }.count, 1, "もう片方は alreadyRunning（順には依存しない）")
        XCTAssertEqual(gateway.fetchedIds, ["a"], "fetch は合計 1 回")
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (d)）
    func testT015_unplayableOrInvalidUrlFailsWithInvalidSourceAndSkipsDownload() async throws {
        XCTAssertNil(URL(string: "http://["), "Given: この文字列は URL にならない")
        let content = episodeContent("a")
        let episodes: [(name: String, episode: Episode)] = [
            ("generating", .generating(GeneratingEpisode(content: content))),
            ("failed", .failed(FailedEpisode(content: content, reportedMessage: nil))),
            ("invalid url", try playableEpisode("a", audioUrl: "http://[")),
        ]
        for (name, episode) in episodes {
            let (library, _) = makeLibrary()
            let gateway = GatewayDouble()
            gateway.onFetch = { _ in episode }
            let downloads = makeDownloads(library: library, gateway: gateway)

            let error = await thrownError(by: downloads, id: "a")

            XCTAssertEqual(error as? DownloadFailure, .invalidSource, name)
            XCTAssertTrue(gateway.downloadedURLs.isEmpty, "\(name): downloadAudio は呼ばない")
            XCTAssertFalse(library.has("a"), name)
            XCTAssertTrue(downloads.downloadingIds.isEmpty, name)
        }
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (e)。fetch の ApiFailure）
    func testT015_apiFailureFromFetchBecomesApiFailure() async {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.onFetch = { _ in throw ApiFailure.server(status: 500) }
        let downloads = makeDownloads(library: library, gateway: gateway)

        let error = await thrownError(by: downloads, id: "a")

        XCTAssertEqual(error as? DownloadFailure, .api(.server(status: 500)))
        XCTAssertFalse(library.has("a"))
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (e)。download の ApiFailure）
    func testT015_apiFailureFromDownloadBecomesApiFailure() async {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.onDownload = { _ in throw ApiFailure.network(URLError(.timedOut)) }
        let downloads = makeDownloads(library: library, gateway: gateway)

        let error = await thrownError(by: downloads, id: "a")

        XCTAssertEqual(error as? DownloadFailure, .api(.network(URLError(.timedOut))))
        XCTAssertFalse(library.has("a"))
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (f)）
    func testT015_saveFailureBecomesStoreFailure() async {
        let (library, _) = makeLibrary(fileManager: FailingWriteFileManager())
        let gateway = GatewayDouble()
        let downloads = makeDownloads(library: library, gateway: gateway)

        let error = await thrownError(by: downloads, id: "a")

        guard case .store = error as? DownloadFailure else {
            return XCTFail("DownloadFailure.store のはずが \(String(describing: error))")
        }
        XCTAssertFalse(library.has("a"))
        XCTAssertFalse(library.savedIds.contains("a"))
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (h)。任意の Error は変換しない）
    func testT015_unknownErrorFromFetchIsRethrownUnchanged() async {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.onFetch = { _ in throw OddFailure() }
        let downloads = makeDownloads(library: library, gateway: gateway)

        let error = await thrownError(by: downloads, id: "a")

        XCTAssertEqual(error as? OddFailure, OddFailure())
        XCTAssertNil(error as? DownloadFailure)
        XCTAssertFalse(library.has("a"))
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (h)。cancel 系は変換しない）
    func testT015_urlErrorCancelledFromDownloadIsRethrownUnchanged() async {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.onDownload = { _ in throw URLError(.cancelled) }
        let downloads = makeDownloads(library: library, gateway: gateway)

        let error = await thrownError(by: downloads, id: "a")

        XCTAssertEqual((error as? URLError)?.code, .cancelled)
        XCTAssertNil(error as? DownloadFailure, ".api に変換しない")
        XCTAssertFalse(library.has("a"))
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
    }

    // verifies: ios-cmd-playback-18, ios-rule-playback-08（ios-test-015 (g)。失敗の後は改めて取得できる）
    func testT015_downloadAfterFailureFetchesAgainInsteadOfAlreadyRunning() async throws {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        var calls = 0
        gateway.onFetch = { id in
            calls += 1
            if calls == 1 { throw ApiFailure.server(status: 503) }
            return try playableEpisode(id)
        }
        let downloads = makeDownloads(library: library, gateway: gateway)
        let firstError = await thrownError(by: downloads, id: "a")
        XCTAssertEqual(firstError as? DownloadFailure, .api(.server(status: 503)), "Given: 1 回目は失敗")

        let receipt: DownloadReceipt = try await downloads.download(episodeId: "a")

        XCTAssertEqual(receipt, .saved)
        XCTAssertEqual(gateway.fetchedIds, ["a", "a"], "fetch は合計 2 回")
    }

    // MARK: ios-test-016 ios-cmd-playback-19

    // verifies: ios-cmd-playback-19（ios-test-016）
    func testT016_removeDeletesSavedIdAndIgnoresUnknownId() throws {
        let (library, _) = makeLibrary()
        try library.save(Data([1]), for: "a")
        let downloads = makeDownloads(library: library, gateway: GatewayDouble())

        try downloads.remove(episodeId: "a")
        try downloads.remove(episodeId: "never")

        XCTAssertFalse(library.has("a"))
        XCTAssertEqual(downloads.state(for: "a"), .notDownloaded)
        XCTAssertFalse(library.savedIds.contains("a"))
    }

    // verifies: ios-cmd-playback-19（ios-test-016。失敗は .store で savedIds は実体と一致）
    func testT016_failedRemoveThrowsStoreFailureAndRealignsSavedIds() throws {
        let failing = FailingRemoveFileManager()
        let (library, cache) = makeLibrary(fileManager: failing)
        try library.save(Data([1]), for: "a")
        try library.save(Data([1]), for: "b")
        failing.files.removeValue(forKey: cache.cachedURL(for: "b").path)  // b は実体だけが消えた
        let downloads = makeDownloads(library: library, gateway: GatewayDouble())

        XCTAssertThrowsError(try downloads.remove(episodeId: "a")) { error in
            guard case .store = error as? DownloadFailure else {
                return XCTFail("DownloadFailure.store のはずが \(error)")
            }
        }

        XCTAssertEqual(library.savedIds, ["a"])
        XCTAssertTrue(library.has("a"))
    }

    // verifies: ios-cmd-playback-19（ios-test-016）
    func testT016_removeAllClearsEverythingAndIsRepeatable() throws {
        let (library, _) = makeLibrary()
        try library.save(Data([1]), for: "a")
        try library.save(Data([1]), for: "b")
        let downloads = makeDownloads(library: library, gateway: GatewayDouble())

        try downloads.removeAll()
        try downloads.removeAll()

        XCTAssertTrue(library.savedIds.isEmpty)
        XCTAssertFalse(library.has("a"))
        XCTAssertFalse(library.has("b"))
    }

    // verifies: ios-cmd-playback-19（ios-test-016。removeAll の失敗）
    func testT016_failedRemoveAllThrowsStoreFailureAndRealignsSavedIds() throws {
        let failing = FailingRemoveFileManager()
        let (library, cache) = makeLibrary(fileManager: failing)
        try library.save(Data([1]), for: "a")
        try library.save(Data([1]), for: "b")
        failing.files.removeValue(forKey: cache.cachedURL(for: "b").path)
        let downloads = makeDownloads(library: library, gateway: GatewayDouble())

        XCTAssertThrowsError(try downloads.removeAll()) { error in
            guard case .store = error as? DownloadFailure else {
                return XCTFail("DownloadFailure.store のはずが \(error)")
            }
        }

        XCTAssertEqual(library.savedIds, ["a"])
    }

    // MARK: ios-test-017 ios-cmd-playback-20

    // verifies: ios-cmd-playback-20, ios-rule-playback-08（ios-test-017）
    // kills: downloadAudio と save の間の Task.checkCancellation() を外す／cancelAll が待つ／cancel の error を .api に変換する
    func testT017_cancelAllReturnsImmediatelyAndCancelledDownloadsAreNotSaved() async {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.holdsDownloads = true
        let downloads = makeDownloads(library: library, gateway: gateway)
        let taskA = Task { try await downloads.download(episodeId: "a") }
        let taskB = Task { try await downloads.download(episodeId: "b") }
        await gateway.waitUntilEntered(2)

        downloads.cancelAll()

        XCTAssertEqual(downloads.downloadingIds, ["a", "b"], "待たずに戻った。終わるまで downloadingIds に残る")
        XCTAssertEqual(gateway.pendingCount, 2, "取得の double は未解放")
        gateway.releaseAll()
        let resultA = await taskA.result
        let resultB = await taskB.result
        for (id, result) in [("a", resultA), ("b", resultB)] {
            switch result {
            case .success(let receipt):
                XCTFail("\(id): cancel されたのに \(receipt) を返した")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "\(id): cancel の error をそのまま投げる（実際: \(error)）")
            }
            XCTAssertFalse(library.has(id), "\(id): cancel された取得の data は保存しない")
        }
        XCTAssertTrue(downloads.downloadingIds.isEmpty)
        downloads.cancelAll()
        XCTAssertTrue(downloads.downloadingIds.isEmpty, "実行中が無ければ何もしない")
    }

    // MARK: ios-test-033 ios-query-playback-04

    // verifies: ios-query-playback-04（ios-test-033。notDownloaded と downloaded）
    func testT033_stateIsNotDownloadedThenDownloaded() throws {
        let (library, _) = makeLibrary()
        let downloads = makeDownloads(library: library, gateway: GatewayDouble())
        XCTAssertEqual(downloads.state(for: "a"), .notDownloaded)
        XCTAssertTrue(downloads.downloadingIds.isEmpty, "初期値は空")

        try library.save(Data([1]), for: "b")

        XCTAssertEqual(downloads.state(for: "b"), .downloaded)
        XCTAssertEqual(downloads.state(for: "a"), .notDownloaded)
    }

    // verifies: ios-query-playback-04（ios-test-033。downloading が downloaded に優先する）
    func testT033_downloadingTakesPriorityOverDownloaded() async throws {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.holdsDownloads = true
        let downloads = makeDownloads(library: library, gateway: gateway)
        let task = Task { try await downloads.download(episodeId: "a") }
        await gateway.waitUntilEntered(1)
        try library.save(Data([1]), for: "a")  // 実体もある

        XCTAssertEqual(downloads.state(for: "a"), .downloading)

        gateway.releaseAll()
        _ = try await task.value
        XCTAssertEqual(downloads.state(for: "a"), .downloaded)
    }

    // MARK: ios-test-115 ios-check-07

    // verifies: ios-query-playback-04, ios-check-07（ios-test-115）
    func testT115_mutatingACopyOfDownloadingIdsDoesNotAffectState() async throws {
        let (library, _) = makeLibrary()
        let gateway = GatewayDouble()
        gateway.holdsDownloads = true
        let downloads = makeDownloads(library: library, gateway: gateway)
        let task = Task { try await downloads.download(episodeId: "a") }
        await gateway.waitUntilEntered(1)

        var copy = downloads.downloadingIds
        copy.remove("a")
        copy.insert("z")

        XCTAssertEqual(downloads.state(for: "a"), .downloading)
        XCTAssertEqual(downloads.state(for: "z"), .notDownloaded)
        XCTAssertEqual(downloads.downloadingIds, ["a"])
        gateway.releaseAll()
        _ = try await task.value
    }
}
