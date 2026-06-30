import XCTest
@testable import NewsListenApp

/// 再生キュー（issue #81）の純粋ロジックの単体テスト。自動次再生・空キュー停止・並べ替え等。
final class PlaybackQueueTests: XCTestCase {

    private func podcast(_ id: String) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://example.com/\(id).wav", japaneseIntroText: "intro",
            durationSeconds: 120, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0
        )
    }

    func testAdvanceMovesToNextThenStopsAtEnd() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        XCTAssertEqual(q.current?.id, "a")
        XCTAssertEqual(q.advance()?.id, "b")
        XCTAssertEqual(q.advance()?.id, "c")
        XCTAssertNil(q.advance())            // 末尾 → 停止
        XCTAssertEqual(q.current?.id, "c")   // 現在は末尾のまま
    }

    func testAdvanceOnEmptyQueueReturnsNil() {
        var q = PlaybackQueue()
        XCTAssertNil(q.advance())
        XCTAssertTrue(q.isEmpty)
    }

    func testStartReplacesQueueWithSingleEpisode() {
        var q = PlaybackQueue()
        q.setQueue([podcast("x"), podcast("y")], startAt: 0)
        q.start(with: podcast("z"))

        XCTAssertEqual(q.items.map { $0.id }, ["z"])
        XCTAssertEqual(q.current?.id, "z")
        XCTAssertNil(q.advance())
    }

    func testAddAppendsAndDeduplicates() {
        var q = PlaybackQueue()
        q.start(with: podcast("a"))
        q.add(podcast("b"))
        q.add(podcast("b"))   // 重複は無視

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
    }

    func testPlayNextInsertsRightAfterCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)  // 現在 b

        q.playNext(podcast("d"))

        XCTAssertEqual(q.current?.id, "b")
        XCTAssertEqual(q.upNext.map { $0.id }, ["d", "c"])   // d が b の直後
    }

    func testPlayNextMovesExistingItemAfterCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)  // 現在 a

        q.playNext(podcast("c"))   // 既存 c を a の直後へ

        XCTAssertEqual(q.items.map { $0.id }, ["a", "c", "b"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testUpNextExcludesCurrentAndPlayed() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)
        XCTAssertEqual(q.upNext.map { $0.id }, ["c"])
    }

    func testRemoveUpNextItem() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        q.remove(id: "c")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testRemoveItemBeforeCurrentKeepsCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 2)  // 現在 c

        q.remove(id: "a")

        XCTAssertEqual(q.items.map { $0.id }, ["b", "c"])
        XCTAssertEqual(q.current?.id, "c")   // 現在は追従
    }

    func testRemoveCurrentPromotesNext() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)  // 現在 b

        q.remove(id: "b")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "c"])
        XCTAssertEqual(q.current?.id, "c")   // 同位置の次（c）が現在に
    }

    func testReorderUpNextKeepsCurrentFixed() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)  // 現在 a, upNext [b,c,d]

        // upNext 内で d(index 2) を先頭(0)へ移動（SwiftUI onMove 規約）。
        q.reorderUpNext(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(q.upNext.map { $0.id }, ["d", "b", "c"])
        XCTAssertEqual(q.current?.id, "a")   // 現在は不変
    }

    func testJumpToExistingItemSetsCurrent() {
        var q = PlaybackQueue()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        XCTAssertTrue(q.jump(to: "c"))
        XCTAssertEqual(q.current?.id, "c")
        XCTAssertFalse(q.jump(to: "zzz"))   // 不在は false・現在は不変
        XCTAssertEqual(q.current?.id, "c")
    }

}
