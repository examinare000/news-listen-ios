import XCTest
@testable import NewsListenApp

final class AudioCacheManagerTests: XCTestCase {

    // MARK: - MockFileManager

    /// テスト用のモック FileManager。インメモリで file 操作を模擬する。
    final class MockFileManager: FileManagerProtocol {
        /// インメモリファイル保存 (path -> data)。テストから操作可能。
        var files: [String: Data] = [:]
        /// ディレクトリ存在フラグ。テストから操作可能。
        var directories: Set<String> = []

        func fileExists(atPath: String) -> Bool {
            files[atPath] != nil || directories.contains(atPath)
        }

        func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
            directories.insert(at.path)
        }

        func removeItem(at: URL) throws {
            files.removeValue(forKey: at.path)
        }

        func write(_ data: Data, to: URL) throws {
            files[to.path] = data
        }

        func fileSize(atPath: String) -> Int64? {
            files[atPath]?.count.int64 ?? nil
        }

        func cachesDirectory() -> URL {
            URL(fileURLWithPath: "/mock-caches")
        }

        func contentsOfDirectory(atPath path: String) throws -> [String] {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return files.keys.compactMap { key in
                guard key.hasPrefix(prefix) else { return nil }
                let name = String(key.dropFirst(prefix.count))
                // 直下のみ対象（サブディレクトリの中身は除外）。
                return name.contains("/") ? nil : name
            }
        }
    }

    // MARK: - Tests

    func testCachedURLReturnsCorrectPath() {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        let url = manager.cachedURL(for: "podcast-123")

        XCTAssertTrue(url.path.hasSuffix("audio-cache/podcast-123.mp3"))
    }

    func testCacheAddsFileAndIsCachedReturnsTrue() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio-cache")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test audio data".data(using: .utf8)!

        try manager.cache(data, for: "podcast-123")

        XCTAssertTrue(manager.isCached("podcast-123"))
    }

    func testIsCachedReturnsFalseBeforeCache() {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        XCTAssertFalse(manager.isCached("podcast-123"))
    }

    func testIsCachedReturnsFalseAfterRemove() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio-cache")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test audio data".data(using: .utf8)!

        try manager.cache(data, for: "podcast-123")
        XCTAssertTrue(manager.isCached("podcast-123"))

        try manager.remove("podcast-123")
        XCTAssertFalse(manager.isCached("podcast-123"))
    }

    func testRemoveIsIdempotent() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        // 存在しないファイルを削除してもエラーにならない
        try manager.remove("nonexistent-podcast")
        // 再度削除してもエラーにならない
        try manager.remove("nonexistent-podcast")
    }

    func testCacheSizeReturnsZeroInitially() {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        XCTAssertEqual(manager.cacheSize(), 0)
    }

    func testCacheSizeReturnsTotalSize() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio-cache")

        let manager = AudioCacheManager(fileManager: mock)
        let data1 = "audio1".data(using: .utf8)!  // 6 bytes
        let data2 = "audio2".data(using: .utf8)!  // 6 bytes

        try manager.cache(data1, for: "podcast-1")
        try manager.cache(data2, for: "podcast-2")

        XCTAssertEqual(manager.cacheSize(), 12)
    }

    // MARK: - キャッシュ全削除 (issue #52)

    func testClearCacheRemovesAllFilesAndIsCachedReturnsFalse() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio-cache")

        let manager = AudioCacheManager(fileManager: mock)
        try manager.cache("audio1".data(using: .utf8)!, for: "podcast-1")
        try manager.cache("audio2".data(using: .utf8)!, for: "podcast-2")

        try manager.clearCache()

        XCTAssertFalse(manager.isCached("podcast-1"))
        XCTAssertFalse(manager.isCached("podcast-2"))
        XCTAssertEqual(manager.cacheSize(), 0)
    }

    func testClearCacheIsIdempotentWhenCacheDirectoryMissing() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        // キャッシュディレクトリ未作成でも例外を投げない（no-op・冪等）。
        try manager.clearCache()
    }

    func testInvalidIdThrowsError() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio-cache")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        do {
            try manager.cache(data, for: "../etc/passwd")
            XCTFail("invalid id should throw AudioCacheError.invalidId")
        } catch let error as AudioCacheError {
            XCTAssertEqual(error, .invalidId)
        }
    }

    func testInvalidIdWithSlashThrowsError() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        do {
            try manager.cache(data, for: "podcast/123")
            XCTFail("invalid id with / should throw")
        } catch let error as AudioCacheError {
            XCTAssertEqual(error, .invalidId)
        }
    }

    func testValidIdFormatsAreAllowed() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio-cache")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        // These should all succeed
        try manager.cache(data, for: "podcast123")
        try manager.cache(data, for: "podcast_456")
        try manager.cache(data, for: "podcast-789")
        try manager.cache(data, for: "PodCast_ABC-123")
    }

    func testEmptyIdThrowsError() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        do {
            try manager.cache(data, for: "")
            XCTFail("empty id should throw")
        } catch let error as AudioCacheError {
            XCTAssertEqual(error, .invalidId)
        }
    }
}

// MARK: - Int extensions

extension Int {
    var int64: Int64 { Int64(self) }
}
