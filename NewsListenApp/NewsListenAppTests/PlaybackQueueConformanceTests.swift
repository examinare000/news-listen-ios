import XCTest
@testable import NewsListenApp

/// クロスプラットフォーム共有仕様（docs/design/shared-playback-spec.md §4.1）の
/// 正本テストケース表 Q-01〜Q-32 の準拠テスト。
///
/// 各テストメソッド名に行 ID を含め、正本の行と 1 対 1 で対応させる（§5 準拠テストの規約）。
/// 既存の PlaybackQueueTests.swift は変更・削除せず、本ファイルと併存させる。
final class PlaybackQueueConformanceTests: XCTestCase {

    private func podcast(_ id: String) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://example.com/\(id).wav", title: "",
            japaneseIntroText: "intro",
            durationSeconds: 120, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0
        )
    }

    // MARK: - Q-01/Q-02: current / upNext アクセサ

    func testQ01_currentAndUpNextWithCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)

        XCTAssertEqual(q.current?.id, "b")
        XCTAssertEqual(q.upNext.map { $0.id }, ["c"])
    }

    func testQ02_currentAndUpNextWithoutCurrent() {
        let q = PlaybackQueue(items: [podcast("a"), podcast("b")], currentIndex: nil)

        XCTAssertNil(q.current)
        XCTAssertEqual(q.upNext.map { $0.id }, ["a", "b"])
    }

    // MARK: - Q-03: start(podcast)

    func testQ03_startReplacesQueueWithSingleEpisode() {
        var q = PlaybackQueue(items: [podcast("x"), podcast("y")], currentIndex: 0)
        q.start(with: podcast("z"))

        XCTAssertEqual(q.items.map { $0.id }, ["z"])
        XCTAssertEqual(q.current?.id, "z")
    }

    // MARK: - Q-04〜Q-07: setQueue(items, startAt)

    func testQ04_setQueueFromEmptyStartsAtGivenIndex() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b", "c"])
        XCTAssertEqual(q.current?.id, "b")
        XCTAssertEqual(q.upNext.map { $0.id }, ["c"])
    }

    func testQ05_setQueueClampsNegativeStartAtToZero() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: -5)

        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.current?.id, "a")
    }

    func testQ06_setQueueClampsOverflowingStartAtToLastIndex() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 10)

        XCTAssertEqual(q.currentIndex, 2)
        XCTAssertEqual(q.current?.id, "c")
        XCTAssertEqual(q.upNext.map { $0.id }, [])
    }

    func testQ07_setQueueWithEmptyListYieldsEmptyQueue() {
        var q = PlaybackQueue()
        q.setQueue([], startAt: 0)

        XCTAssertEqual(q.items.map { $0.id }, [])
        XCTAssertNil(q.currentIndex)
    }

    // MARK: - Q-08/Q-09: add(podcast)

    func testQ08_addAppendsToTail() {
        var q = PlaybackQueue()
        q.start(with: podcast("a"))
        q.add(podcast("b"))

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
        XCTAssertEqual(q.upNext.map { $0.id }, ["b"])
    }

    func testQ09_addIsNoOpForDuplicateId() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b")], startAt: 0)
        q.add(podcast("b"))

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
    }

    // MARK: - Q-10〜Q-13: playNext(podcast)

    func testQ10_playNextInsertsRightAfterCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)
        q.playNext(podcast("d"))

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b", "d", "c"])
        XCTAssertEqual(q.current?.id, "b")
        XCTAssertEqual(q.upNext.map { $0.id }, ["d", "c"])
    }

    func testQ11_playNextMovesExistingDuplicateAfterCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)
        q.playNext(podcast("c"))

        XCTAssertEqual(q.items.map { $0.id }, ["a", "c", "b"])
        XCTAssertEqual(q.current?.id, "a")
        XCTAssertEqual(q.upNext.map { $0.id }, ["c", "b"])
    }

    func testQ12_playNextForCurrentEpisodeIsNoOp() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)
        q.playNext(podcast("a"))

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b", "c"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testQ13_playNextWithoutCurrentInsertsAtHead() {
        var q = PlaybackQueue(items: [podcast("a"), podcast("b")], currentIndex: nil)
        q.playNext(podcast("c"))

        XCTAssertEqual(q.items.map { $0.id }, ["c", "a", "b"])
        XCTAssertNil(q.currentIndex)
    }

    // MARK: - Q-14/Q-15: jump(id)

    func testQ14_jumpToExistingItemSetsCurrentAndReturnsTrue() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        XCTAssertTrue(q.jump(to: "c"))
        XCTAssertEqual(q.current?.id, "c")
    }

    func testQ15_jumpToMissingItemReturnsFalseAndLeavesCurrentUnchanged() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        XCTAssertFalse(q.jump(to: "zzz"))
        XCTAssertEqual(q.current?.id, "a")
    }

    // MARK: - Q-16〜Q-19: advance()

    func testQ16_advanceFromNoCurrentStartsAtHead() {
        var q = PlaybackQueue(items: [podcast("a"), podcast("b"), podcast("c")], currentIndex: nil)
        let next = q.advance()

        XCTAssertEqual(next?.id, "a")
        XCTAssertEqual(q.currentIndex, 0)
    }

    func testQ17_advanceMovesToNextItem() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)
        let next = q.advance()

        XCTAssertEqual(next?.id, "b")
        XCTAssertEqual(q.currentIndex, 1)
    }

    func testQ18_advanceAtTailStopsAndKeepsCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 2)
        let next = q.advance()

        XCTAssertNil(next)
        XCTAssertEqual(q.current?.id, "c")
    }

    func testQ19_advanceOnEmptyQueueReturnsNil() {
        var q = PlaybackQueue(items: [], currentIndex: nil)
        XCTAssertNil(q.advance())
    }

    // MARK: - Q-20〜Q-25: remove(id)

    func testQ20_removeItemBeforeCurrentShiftsCurrentIndexDown() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 2)
        q.remove(id: "a")

        XCTAssertEqual(q.items.map { $0.id }, ["b", "c"])
        XCTAssertEqual(q.current?.id, "c")
    }

    func testQ21_removeCurrentItemPromotesNext() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)
        q.remove(id: "b")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "c"])
        XCTAssertEqual(q.current?.id, "c")
    }

    func testQ22_removeCurrentAtTailClampsToNewTail() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 2)
        q.remove(id: "c")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
        XCTAssertEqual(q.current?.id, "b")
    }

    func testQ23_removeItemAfterCurrentLeavesCurrentUnaffected() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)
        q.remove(id: "c")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testQ24_removeMissingIdIsNoOp() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)
        q.remove(id: "zzz")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b", "c"])
        XCTAssertEqual(q.current?.id, "b")
    }

    func testQ25_removeLastRemainingItemEmptiesQueue() {
        var q = PlaybackQueue()
        q.start(with: podcast("a"))
        q.remove(id: "a")

        XCTAssertEqual(q.items.map { $0.id }, [])
        XCTAssertNil(q.currentIndex)
    }

    // MARK: - Q-26〜Q-32: moveUpNext(from, toOffset) — 正本 = iOS onMove（削除前オフセット方式）
    //
    // iOS の `reorderUpNext(fromOffsets:toOffset:)` は単一要素の IndexSet で呼ぶ（正本の
    // moveUpNext(from, toOffset) と等価）。正本は本方式を単一のソース・オブ・トゥルースとしており、
    // Q-26/Q-28/Q-32 は旧 web（splice 方式）との乖離検出行だが iOS 自身は乖離しない想定。

    func testQ26_moveUpNextForwardUsesOnMoveSemantics() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)
        q.reorderUpNext(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        XCTAssertEqual(q.upNext.map { $0.id }, ["c", "b", "d"])
        XCTAssertEqual(q.items.map { $0.id }, ["a", "c", "b", "d"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testQ27_moveUpNextBackwardMatchesBothSemantics() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)
        q.reorderUpNext(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(q.upNext.map { $0.id }, ["d", "b", "c"])
        XCTAssertEqual(q.items.map { $0.id }, ["a", "d", "b", "c"])
    }

    func testQ28_moveUpNextToOffsetEqualsCountMovesToTail() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)
        // upNext count = 3。toOffset == count は末尾への移動（onMove 規約）。
        q.reorderUpNext(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(q.upNext.map { $0.id }, ["c", "d", "b"])
        XCTAssertEqual(q.items.map { $0.id }, ["a", "c", "d", "b"])
    }

    func testQ29_moveUpNextWithOutOfRangeToOffsetIsNoOp() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)
        // upNext count = 3。有効な toOffset は [0, 3]。4 は範囲外 ⟹ 正本は無変更（no-op）。
        q.reorderUpNext(fromOffsets: IndexSet(integer: 0), toOffset: 4)

        XCTAssertEqual(q.upNext.map { $0.id }, ["b", "c", "d"])
        XCTAssertEqual(q.items.map { $0.id }, ["a", "b", "c", "d"])
    }

    func testQ30_moveUpNextWithOutOfRangeFromIsNoOp() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)
        // upNext count = 3。有効な from は [0, 2]。5 は範囲外 ⟹ 正本は無変更（no-op）。
        q.reorderUpNext(fromOffsets: IndexSet(integer: 5), toOffset: 0)

        XCTAssertEqual(q.upNext.map { $0.id }, ["b", "c", "d"])
        XCTAssertEqual(q.items.map { $0.id }, ["a", "b", "c", "d"])
    }

    func testQ31_moveUpNextToSamePositionIsNoOp() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)
        q.reorderUpNext(fromOffsets: IndexSet(integer: 1), toOffset: 1)

        XCTAssertEqual(q.upNext.map { $0.id }, ["b", "c", "d"])
    }

    func testQ32_moveUpNextWithoutCurrentOperatesOnWholeQueue() {
        var q = PlaybackQueue(items: [podcast("a"), podcast("b"), podcast("c")], currentIndex: nil)
        q.reorderUpNext(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        XCTAssertEqual(q.upNext.map { $0.id }, ["b", "a", "c"])
        XCTAssertEqual(q.items.map { $0.id }, ["b", "a", "c"])
        XCTAssertNil(q.currentIndex)
    }
}
