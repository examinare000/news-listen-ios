import XCTest
@testable import NewsListenApp

/// `OfflineLibrary`（保存済みの集合と保存庫 port の窓口）の契約テスト。
///
/// 保存庫は `AudioFileStore.live(cacheManager:)` を、インメモリの `FileManagerProtocol` 越しの `AudioCacheManager` に被せて使う。
/// 実機のキャッシュディレクトリには触れない。
@MainActor
final class OfflineLibraryTests: XCTestCase {

    private func makeLibrary(
        fileManager: FileManagerProtocol = AudioCacheManagerTests.MockFileManager()
    ) -> (library: OfflineLibrary, cache: AudioCacheManager) {
        let cache = AudioCacheManager(fileManager: fileManager)
        return (OfflineLibrary(store: .live(cacheManager: cache)), cache)
    }

    private func data(_ size: Int) -> Data { Data(repeating: 0x41, count: size) }

    // verifies: ios-contract-16（ios-test-095）
    func testT095_saveMakesHasTrueAndAddsToSavedIds() throws {
        let (library, _) = makeLibrary()
        XCTAssertTrue(library.savedIds.isEmpty, "初期値は空")
        XCTAssertFalse(library.has("a"))

        try library.save(data(10), for: "a")

        XCTAssertTrue(library.has("a"))
        XCTAssertEqual(library.savedIds, ["a"])
        XCTAssertFalse(library.has("b"), "保存していない id は false")
    }

    // verifies: ios-contract-16（ios-test-095）
    func testT095_removeMakesHasFalseAndDropsOnlyThatId() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a")
        try library.save(data(1), for: "b")

        try library.remove("a")

        XCTAssertFalse(library.has("a"))
        XCTAssertTrue(library.has("b"))
        XCTAssertEqual(library.savedIds, ["b"])
    }

    // verifies: ios-contract-16（ios-test-095）
    func testT095_clearAllEmptiesTheLibrary() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a")
        try library.save(data(1), for: "b")

        try library.clearAll()

        XCTAssertFalse(library.has("a"))
        XCTAssertFalse(library.has("b"))
        XCTAssertTrue(library.savedIds.isEmpty)
    }

    // verifies: ios-contract-16（ios-test-095。refresh は実体のある id だけ）
    func testT095_refreshKeepsOnlyCandidatesThatExistInTheStore() throws {
        let mock = AudioCacheManagerTests.MockFileManager()
        let (library, cache) = makeLibrary(fileManager: mock)
        try library.save(data(1), for: "a")
        try library.save(data(1), for: "b")
        mock.files.removeValue(forKey: cache.cachedURL(for: "b").path)  // 実体だけが消えた

        library.refresh(candidateIds: ["a", "b", "c"])

        XCTAssertEqual(library.savedIds, ["a"], "実体のある候補だけ。b は実体が無く、c は元から無い")
    }

    // verifies: ios-contract-16（ios-test-095。refresh は候補の外の id を持ち越さない）
    func testT095_refreshDropsSavedIdsOutsideTheCandidates() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a")
        try library.save(data(1), for: "b")

        library.refresh(candidateIds: ["a"])

        XCTAssertEqual(library.savedIds, ["a"], "savedIds = Set(candidateIds.filter(has))")
    }

    // verifies: ios-contract-16（ios-test-095。url は無ければ nil）
    func testT095_urlIsNilUnlessTheFileExists() throws {
        let (library, cache) = makeLibrary()
        XCTAssertNil(library.url("a"))

        try library.save(data(1), for: "a")

        XCTAssertEqual(library.url("a"), cache.cachedURL(for: "a"))
        XCTAssertNil(library.url("b"))
    }

    // verifies: ios-contract-16（usage() は store.size()）
    func testUsageReturnsTheStoreSize() throws {
        let (library, _) = makeLibrary()
        XCTAssertEqual(library.usage(), 0)

        try library.save(data(10), for: "a")
        try library.save(data(5), for: "b")

        XCTAssertEqual(library.usage(), 15)
    }

    // verifies: ios-contract-16（ios-test-095。削除の失敗: savedIds は実体と一致したまま throw）
    // kills: 失敗しても savedIds を触らない／失敗する前に id を外す
    func testT095_failedRemoveRealignsSavedIdsToTheStoreAndThrows() throws {
        let failing = FailingRemoveFileManager()
        let (library, cache) = makeLibrary(fileManager: failing)
        try library.save(data(1), for: "a")
        try library.save(data(1), for: "b")
        failing.files.removeValue(forKey: cache.cachedURL(for: "b").path)  // savedIds は b を持つが実体は無い
        XCTAssertEqual(library.savedIds, ["a", "b"], "Given: savedIds と実体がずれている")

        XCTAssertThrowsError(try library.remove("a"))

        XCTAssertEqual(library.savedIds, ["a"], "失敗したので a は残り、実体のない b は外れる（savedIds.filter(has)）")
        XCTAssertTrue(library.has("a"))
    }

    // verifies: ios-contract-16（ios-test-095。clearAll の失敗）
    func testT095_failedClearAllRealignsSavedIdsToTheStoreAndThrows() throws {
        let failing = FailingRemoveFileManager()
        let (library, cache) = makeLibrary(fileManager: failing)
        try library.save(data(1), for: "a")
        try library.save(data(1), for: "b")
        failing.files.removeValue(forKey: cache.cachedURL(for: "b").path)

        XCTAssertThrowsError(try library.clearAll())

        XCTAssertEqual(library.savedIds, ["a"])
        XCTAssertTrue(library.has("a"))
    }
}
