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
        let library = OfflineLibrary(store: .live(cacheManager: cache))
        library.bind(subject: subjectA)
        return (library, cache)
    }

    private func data(_ size: Int) -> Data { Data(repeating: 0x41, count: size) }

    // verifies: ios-contract-16（ios-test-095）
    func testT095_saveMakesHasTrueAndAddsToSavedIds() throws {
        let (library, _) = makeLibrary()
        XCTAssertTrue(library.savedIds.isEmpty, "初期値は空")
        XCTAssertFalse(library.has("a"))

        try library.save(data(10), for: "a", subject: subjectA)

        XCTAssertTrue(library.has("a"))
        XCTAssertEqual(library.savedIds, ["a"])
        XCTAssertFalse(library.has("b"), "保存していない id は false")
    }

    // verifies: ios-contract-16（ios-test-095）
    func testT095_removeMakesHasFalseAndDropsOnlyThatId() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a", subject: subjectA)
        try library.save(data(1), for: "b", subject: subjectA)

        try library.remove("a")

        XCTAssertFalse(library.has("a"))
        XCTAssertTrue(library.has("b"))
        XCTAssertEqual(library.savedIds, ["b"])
    }

    // verifies: ios-contract-16（ios-test-095）
    func testRemoveSubjectEmptiesTheBoundSubject() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a", subject: subjectA)
        try library.save(data(1), for: "b", subject: subjectA)

        try library.remove(subject: subjectA)

        XCTAssertFalse(library.has("a"))
        XCTAssertFalse(library.has("b"))
        XCTAssertTrue(library.savedIds.isEmpty)
    }

    // verifies: ios-contract-16（ios-test-095。refresh は実体のある id だけ）
    func testT095_refreshKeepsOnlyCandidatesThatExistInTheStore() throws {
        let mock = AudioCacheManagerTests.MockFileManager()
        let (library, cache) = makeLibrary(fileManager: mock)
        try library.save(data(1), for: "a", subject: subjectA)
        try library.save(data(1), for: "b", subject: subjectA)
        mock.files.removeValue(forKey: cache.cachedURL(for: "b", subject: subjectA).path)  // 実体だけが消えた

        library.refresh(candidateIds: ["a", "b", "c"])

        XCTAssertEqual(library.savedIds, ["a"], "実体のある候補だけ。b は実体が無く、c は元から無い")
    }

    // verifies: ios-contract-16（ios-test-095。refresh は候補の外の id を持ち越さない）
    func testT095_refreshDropsSavedIdsOutsideTheCandidates() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a", subject: subjectA)
        try library.save(data(1), for: "b", subject: subjectA)

        library.refresh(candidateIds: ["a"])

        XCTAssertEqual(library.savedIds, ["a"], "savedIds = Set(candidateIds.filter(has))")
    }

    // verifies: ios-contract-16（ios-test-095。url は無ければ nil）
    func testT095_urlIsNilUnlessTheFileExists() throws {
        let (library, cache) = makeLibrary()
        XCTAssertNil(library.url("a"))

        try library.save(data(1), for: "a", subject: subjectA)

        XCTAssertEqual(library.url("a"), cache.cachedURL(for: "a", subject: subjectA))
        XCTAssertNil(library.url("b"))
    }

    // verifies: ios-contract-16（usage() は store.size()）
    func testUsageReturnsTheStoreSize() throws {
        let (library, _) = makeLibrary()
        XCTAssertEqual(library.usage(), 0)

        try library.save(data(10), for: "a", subject: subjectA)
        try library.save(data(5), for: "b", subject: subjectA)

        XCTAssertEqual(library.usage(), 15)
    }

    // verifies: ios-contract-16（ios-test-095。削除の失敗: savedIds は実体と一致したまま throw）
    // kills: 失敗しても savedIds を触らない／失敗する前に id を外す
    func testT095_failedRemoveRealignsSavedIdsToTheStoreAndThrows() throws {
        let failing = FailingRemoveFileManager()
        let (library, cache) = makeLibrary(fileManager: failing)
        try library.save(data(1), for: "a", subject: subjectA)
        try library.save(data(1), for: "b", subject: subjectA)
        failing.files.removeValue(forKey: cache.cachedURL(for: "b", subject: subjectA).path)  // savedIds は b を持つが実体は無い
        XCTAssertEqual(library.savedIds, ["a", "b"], "Given: savedIds と実体がずれている")

        XCTAssertThrowsError(try library.remove("a"))

        XCTAssertEqual(library.savedIds, ["a"], "失敗したので a は残り、実体のない b は外れる（savedIds.filter(has)）")
        XCTAssertTrue(library.has("a"))
    }

    // verifies: ios-contract-16（ios-test-095。remove(subject:) の失敗）
    func testT095_failedRemoveSubjectRealignsSavedIdsToTheStoreAndThrows() throws {
        let failing = FailingRemoveFileManager()
        let (library, cache) = makeLibrary(fileManager: failing)
        try library.save(data(1), for: "a", subject: subjectA)
        try library.save(data(1), for: "b", subject: subjectA)
        failing.files.removeValue(forKey: cache.cachedURL(for: "b", subject: subjectA).path)

        XCTAssertThrowsError(try library.remove(subject: subjectA))

        XCTAssertEqual(library.savedIds, ["a"])
        XCTAssertTrue(library.has("a"))
    }

    // MARK: - 束縛と主体

    private func fileKey(_ id: String, _ subject: String) -> String {
        "/mock-caches/NewsListenApp/audio/\(subject)/\(id).mp3"
    }

    // verifies: ios-contract-16（束縛が nil のとき無効）
    func testUnboundLibraryIsDisabled() throws {
        let library = OfflineLibrary(store: .live(cacheManager: AudioCacheManager(fileManager: AudioCacheManagerTests.MockFileManager())))

        XCTAssertFalse(library.has("a"))
        XCTAssertNil(library.url("a"))
        XCTAssertEqual(library.usage(), 0)
        XCTAssertThrowsError(try library.save(data(1), for: "a", subject: nil)) { error in
            XCTAssertEqual(error as? OfflineLibrary.SaveError, .cacheDisabled)
        }
        XCTAssertTrue(library.savedIds.isEmpty)
    }

    // verifies: ios-contract-16（束縛が別の主体のとき、渡された主体のディレクトリへ書き、savedIds には入れない）
    // kills: 束縛中の主体へ書く／書いた id を束縛と無関係に savedIds へ足す
    func testSaveForAnotherSubjectWritesThatSubjectsDirectoryWithoutAddingToSavedIds() throws {
        let mock = AudioCacheManagerTests.MockFileManager()
        let (library, _) = makeLibrary(fileManager: mock)
        library.bind(subject: subjectB)

        try library.save(data(3), for: "p1", subject: subjectA)

        XCTAssertNotNil(mock.files[fileKey("p1", "user-a")], "A のディレクトリに実体がある")
        XCTAssertNil(mock.files[fileKey("p1", "user-b")], "束縛中の B には書かない")
        XCTAssertTrue(library.savedIds.isEmpty)
        XCTAssertFalse(library.has("p1"), "B の範囲に p1 は無い")
    }

    // verifies: ios-contract-16（離脱で束縛が nil になった後でも、渡された主体のディレクトリへ書く。shared-leave-06 の保存庫側）
    // kills: save を束縛で判定して束縛 nil のとき cacheDisabled にする／書き込みを捨てる
    func testSaveForSubjectAfterUnbindStillWritesThatSubjectsDirectory() throws {
        let mock = AudioCacheManagerTests.MockFileManager()
        let (library, _) = makeLibrary(fileManager: mock)
        library.bind(subject: nil)

        XCTAssertNoThrow(try library.save(data(3), for: "p1", subject: subjectA))

        XCTAssertNotNil(mock.files[fileKey("p1", "user-a")])
        XCTAssertTrue(library.savedIds.isEmpty)
        XCTAssertFalse(library.has("p1"), "束縛 nil の間は無効")
    }

    // verifies: ios-contract-16（remove(subject:) は束縛中の主体以外の savedIds を変えない）
    func testRemoveSubjectOfAnotherSubjectLeavesTheBoundSavedIds() throws {
        let mock = AudioCacheManagerTests.MockFileManager()
        let (library, _) = makeLibrary(fileManager: mock)
        library.bind(subject: subjectB)
        try library.save(data(1), for: "b1", subject: subjectB)
        try library.save(data(1), for: "a1", subject: subjectA)

        try library.remove(subject: subjectA)

        XCTAssertEqual(library.savedIds, ["b1"])
        XCTAssertNil(mock.files[fileKey("a1", "user-a")], "A の実体は消える")
        XCTAssertNotNil(mock.files[fileKey("b1", "user-b")])
    }

    // verifies: ios-contract-16（remove(subject: nil) は何もしない）
    func testRemoveSubjectNilDoesNothing() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a", subject: subjectA)

        try library.remove(subject: nil)

        XCTAssertEqual(library.savedIds, ["a"])
    }

    // verifies: ios-contract-16（bind は savedIds を空に戻す）
    func testBindEmptiesSavedIds() throws {
        let (library, _) = makeLibrary()
        try library.save(data(1), for: "a", subject: subjectA)
        XCTAssertEqual(library.savedIds, ["a"])

        library.bind(subject: subjectB)

        XCTAssertTrue(library.savedIds.isEmpty)
    }

    // verifies: ios-contract-16（reclaim は keeping 以外を消し、束縛中の主体で savedIds を作り直す）
    func testReclaimKeepingBoundSubjectRemovesOthersAndRebuildsSavedIds() throws {
        let mock = AudioCacheManagerTests.MockFileManager()
        let (library, _) = makeLibrary(fileManager: mock)
        library.bind(subject: subjectB)
        try library.save(data(1), for: "a1", subject: subjectA)
        try library.save(data(1), for: "b1", subject: subjectB)
        library.refresh(candidateIds: ["a1", "b1"])

        try library.reclaim(keeping: subjectB)

        XCTAssertNil(mock.files[fileKey("a1", "user-a")], "A の実体は回収される")
        XCTAssertNotNil(mock.files[fileKey("b1", "user-b")])
        XCTAssertEqual(library.savedIds, ["b1"], "束縛中の B の実体で作り直す")
    }

    // verifies: ios-contract-16（SaveError の利用者向け文言）
    func testSaveErrorCacheDisabledHasUserFacingDescription() {
        XCTAssertEqual(OfflineLibrary.SaveError.cacheDisabled.errorDescription, "オフライン保存を利用できません")
    }
}
