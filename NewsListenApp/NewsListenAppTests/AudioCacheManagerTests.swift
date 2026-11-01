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
            let prefix = atPath + "/"
            return files[atPath] != nil || directories.contains(atPath)
                || files.keys.contains { $0.hasPrefix(prefix) }
                || directories.contains { $0.hasPrefix(prefix) }
        }

        func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
            directories.insert(at.path)
        }

        func removeItem(at: URL) throws {
            let path = at.path
            let prefix = path + "/"
            files = files.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            directories = directories.filter { $0 != path && !$0.hasPrefix(prefix) }
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
            var names: [String] = []
            for key in Array(files.keys) + Array(directories) where key.hasPrefix(prefix) {
                // 直下の項目名（サブディレクトリは先頭の path 成分＝ディレクトリ名）を重複なしで返す。
                let name = String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
                if let name, !names.contains(name) { names.append(name) }
            }
            return names
        }
    }

    /// `removeItem` が常に失敗する FileManager。
    final class ThrowingRemoveFileManager: FileManagerProtocol {
        struct RemoveFailure: Error {}
        var files: [String: Data] = [:]

        func fileExists(atPath: String) -> Bool {
            files[atPath] != nil || files.keys.contains { $0.hasPrefix(atPath + "/") }
        }
        func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {}
        func removeItem(at: URL) throws { throw RemoveFailure() }
        func write(_ data: Data, to: URL) throws { files[to.path] = data }
        func fileSize(atPath: String) -> Int64? { files[atPath]?.count.int64 }
        func cachesDirectory() -> URL { URL(fileURLWithPath: "/mock-caches") }
        func contentsOfDirectory(atPath path: String) throws -> [String] {
            let prefix = path + "/"
            var names: [String] = []
            for key in files.keys where key.hasPrefix(prefix) {
                if let name = String(key.dropFirst(prefix.count)).split(separator: "/").first.map(String.init),
                   !names.contains(name) { names.append(name) }
            }
            return names
        }
    }

    // MARK: - Tests

    func testCachedURLReturnsCorrectPath() {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        let url = manager.cachedURL(for: "podcast-123", subject: subjectA)

        XCTAssertTrue(url.path.hasSuffix("audio/user-a/podcast-123.mp3"))
    }

    func testCacheAddsFileAndIsCachedReturnsTrue() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio/user-a")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test audio data".data(using: .utf8)!

        try manager.cache(data, for: "podcast-123", subject: subjectA)

        XCTAssertTrue(manager.isCached("podcast-123", subject: subjectA))
    }

    func testIsCachedReturnsFalseBeforeCache() {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        XCTAssertFalse(manager.isCached("podcast-123", subject: subjectA))
    }

    func testIsCachedReturnsFalseAfterRemove() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio/user-a")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test audio data".data(using: .utf8)!

        try manager.cache(data, for: "podcast-123", subject: subjectA)
        XCTAssertTrue(manager.isCached("podcast-123", subject: subjectA))

        try manager.remove("podcast-123", subject: subjectA)
        XCTAssertFalse(manager.isCached("podcast-123", subject: subjectA))
    }

    func testRemoveIsIdempotent() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        // 存在しないファイルを削除してもエラーにならない
        try manager.remove("nonexistent-podcast", subject: subjectA)
        // 再度削除してもエラーにならない
        try manager.remove("nonexistent-podcast", subject: subjectA)
    }

    func testCacheSizeReturnsZeroInitially() {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        XCTAssertEqual(manager.cacheSize(subject: subjectA), 0)
    }

    func testCacheSizeReturnsTotalSize() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio/user-a")

        let manager = AudioCacheManager(fileManager: mock)
        let data1 = "audio1".data(using: .utf8)!  // 6 bytes
        let data2 = "audio2".data(using: .utf8)!  // 6 bytes

        try manager.cache(data1, for: "podcast-1", subject: subjectA)
        try manager.cache(data2, for: "podcast-2", subject: subjectA)

        XCTAssertEqual(manager.cacheSize(subject: subjectA), 12)
    }

    // MARK: - テスト double の意味（子を持つ path はディレクトリとして扱う）

    func testMockFileManagerTreatsPathsWithChildrenAsDirectories() throws {
        let mock = MockFileManager()
        mock.files["/mock-caches/NewsListenApp/audio/user-a/p1.mp3"] = Data("a".utf8)
        mock.files["/mock-caches/NewsListenApp/audio/user-b/p1.mp3"] = Data("b".utf8)

        XCTAssertTrue(mock.fileExists(atPath: "/mock-caches/NewsListenApp/audio/user-a"))
        XCTAssertEqual(
            Set(try mock.contentsOfDirectory(atPath: "/mock-caches/NewsListenApp/audio")),
            ["user-a", "user-b"]
        )

        try mock.removeItem(at: URL(fileURLWithPath: "/mock-caches/NewsListenApp/audio/user-a"))

        XCTAssertFalse(mock.fileExists(atPath: "/mock-caches/NewsListenApp/audio/user-a"))
        XCTAssertTrue(mock.fileExists(atPath: "/mock-caches/NewsListenApp/audio/user-b/p1.mp3"))
    }

    // MARK: - 主体ディレクトリの削除

    func testRemoveSubjectRemovesOnlyThatSubjectsFiles() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)
        try manager.cache("audio1".data(using: .utf8)!, for: "podcast-1", subject: subjectA)
        try manager.cache("audio2".data(using: .utf8)!, for: "podcast-2", subject: subjectA)
        try manager.cache("audio3".data(using: .utf8)!, for: "podcast-3", subject: subjectB)

        try manager.removeSubject(subjectA)

        XCTAssertFalse(manager.isCached("podcast-1", subject: subjectA))
        XCTAssertFalse(manager.isCached("podcast-2", subject: subjectA))
        XCTAssertEqual(manager.cacheSize(subject: subjectA), 0)
        XCTAssertTrue(manager.isCached("podcast-3", subject: subjectB))
        XCTAssertEqual(manager.cacheSize(subject: subjectB), 6)
    }

    func testRemoveSubjectIsIdempotentWhenSubjectDirectoryMissing() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        // 主体ディレクトリ未作成でも例外を投げない（no-op・冪等）。2 回目も同じ。
        try manager.removeSubject(subjectA)
        try manager.removeSubject(subjectA)
    }

    // MARK: - 起動時の回収

    private let legacyDirectory = "/mock-caches/NewsListenApp/audio-cache"

    func testReclaimKeepingSubjectRemovesOthersAndLegacyDirectory() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)
        try manager.cache("a".data(using: .utf8)!, for: "p1", subject: subjectA)
        try manager.cache("b".data(using: .utf8)!, for: "p1", subject: subjectB)
        mock.files["\(legacyDirectory)/x.mp3"] = Data("old".utf8)

        try manager.reclaim(keeping: subjectA)

        XCTAssertTrue(manager.isCached("p1", subject: subjectA))
        XCTAssertFalse(manager.isCached("p1", subject: subjectB))
        XCTAssertFalse(mock.fileExists(atPath: legacyDirectory))
    }

    func testReclaimKeepingNilRemovesEverySubject() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)
        try manager.cache("a".data(using: .utf8)!, for: "p1", subject: subjectA)
        try manager.cache("b".data(using: .utf8)!, for: "p1", subject: subjectB)

        try manager.reclaim(keeping: nil)

        XCTAssertFalse(manager.isCached("p1", subject: subjectA))
        XCTAssertFalse(manager.isCached("p1", subject: subjectB))
        XCTAssertEqual(try mock.contentsOfDirectory(atPath: "/mock-caches/NewsListenApp/audio"), [])
    }

    func testReclaimRemovesLegacyDirectoryEvenWhenAudioDirectoryIsMissing() async throws {
        let mock = MockFileManager()
        mock.files["\(legacyDirectory)/x.mp3"] = Data("old".utf8)
        let manager = AudioCacheManager(fileManager: mock)

        try manager.reclaim(keeping: nil)

        XCTAssertFalse(mock.fileExists(atPath: legacyDirectory))
    }

    func testReclaimIsIdempotentWhenNothingExists() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)

        try manager.reclaim(keeping: subjectA)
        try manager.reclaim(keeping: subjectA)
    }

    func testReclaimThrowsWhenRemoveItemFails() async throws {
        let mock = ThrowingRemoveFileManager()
        mock.files["/mock-caches/NewsListenApp/audio/user-b/p1.mp3"] = Data("b".utf8)
        let manager = AudioCacheManager(fileManager: mock)

        XCTAssertThrowsError(try manager.reclaim(keeping: subjectA))
    }

    func testInvalidIdThrowsError() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio/user-a")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        do {
            try manager.cache(data, for: "../etc/passwd", subject: subjectA)
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
            try manager.cache(data, for: "podcast/123", subject: subjectA)
            XCTFail("invalid id with / should throw")
        } catch let error as AudioCacheError {
            XCTAssertEqual(error, .invalidId)
        }
    }

    func testValidIdFormatsAreAllowed() async throws {
        let mock = MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        mock.directories.insert("/mock-caches/NewsListenApp/audio/user-a")

        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        // These should all succeed
        try manager.cache(data, for: "podcast123", subject: subjectA)
        try manager.cache(data, for: "podcast_456", subject: subjectA)
        try manager.cache(data, for: "podcast-789", subject: subjectA)
        try manager.cache(data, for: "PodCast_ABC-123", subject: subjectA)
    }

    func testEmptyIdThrowsError() async throws {
        let mock = MockFileManager()
        let manager = AudioCacheManager(fileManager: mock)
        let data = "test".data(using: .utf8)!

        do {
            try manager.cache(data, for: "", subject: subjectA)
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
