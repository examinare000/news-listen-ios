import XCTest
@testable import NewsListenApp

/// 再生キュー（issue #81）の純粋ロジックの単体テスト。自動次再生・空キュー停止・並べ替え等。
final class PlaybackQueueTests: XCTestCase {

    private func podcast(_ id: String) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://example.com/\(id).wav", title: "",
            japaneseIntroText: "intro",
            durationSeconds: 120, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
    }

    func testAdvanceMovesToNextThenStopsAtEnd() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        XCTAssertEqual(q.current?.id, "a")
        XCTAssertEqual(q.advance()?.id, "b")
        XCTAssertEqual(q.advance()?.id, "c")
        XCTAssertNil(q.advance())            // 末尾 → 停止
        XCTAssertEqual(q.current?.id, "c")   // 現在は末尾のまま
    }

    func testAdvanceOnEmptyQueueReturnsNil() {
        var q = PlaybackQueue<Podcast>()
        XCTAssertNil(q.advance())
        XCTAssertTrue(q.isEmpty)
    }

    func testStartReplacesQueueWithSingleEpisode() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("x"), podcast("y")], startAt: 0)
        q.start(with: podcast("z"))

        XCTAssertEqual(q.items.map { $0.id }, ["z"])
        XCTAssertEqual(q.current?.id, "z")
        XCTAssertNil(q.advance())
    }

    func testAddAppendsAndDeduplicates() {
        var q = PlaybackQueue<Podcast>()
        q.start(with: podcast("a"))
        q.add(podcast("b"))
        q.add(podcast("b"))   // 重複は無視

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
    }

    func testPlayNextInsertsRightAfterCurrent() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)  // 現在 b

        q.playNext(podcast("d"))

        XCTAssertEqual(q.current?.id, "b")
        XCTAssertEqual(q.upNext.map { $0.id }, ["d", "c"])   // d が b の直後
    }

    func testPlayNextMovesExistingItemAfterCurrent() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)  // 現在 a

        q.playNext(podcast("c"))   // 既存 c を a の直後へ

        XCTAssertEqual(q.items.map { $0.id }, ["a", "c", "b"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testUpNextExcludesCurrentAndPlayed() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)
        XCTAssertEqual(q.upNext.map { $0.id }, ["c"])
    }

    func testRemoveUpNextItem() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        q.remove(id: "c")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "b"])
        XCTAssertEqual(q.current?.id, "a")
    }

    func testRemoveItemBeforeCurrentKeepsCurrent() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 2)  // 現在 c

        q.remove(id: "a")

        XCTAssertEqual(q.items.map { $0.id }, ["b", "c"])
        XCTAssertEqual(q.current?.id, "c")   // 現在は追従
    }

    func testRemoveCurrentPromotesNext() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 1)  // 現在 b

        q.remove(id: "b")

        XCTAssertEqual(q.items.map { $0.id }, ["a", "c"])
        XCTAssertEqual(q.current?.id, "c")   // 同位置の次（c）が現在に
    }

    func testReorderUpNextKeepsCurrentFixed() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c"), podcast("d")], startAt: 0)  // 現在 a, upNext [b,c,d]

        // upNext 内で d(index 2) を先頭(0)へ移動（SwiftUI onMove 規約）。
        q.reorderUpNext(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(q.upNext.map { $0.id }, ["d", "b", "c"])
        XCTAssertEqual(q.current?.id, "a")   // 現在は不変
    }

    func testJumpToExistingItemSetsCurrent() {
        var q = PlaybackQueue<Podcast>()
        q.setQueue([podcast("a"), podcast("b"), podcast("c")], startAt: 0)

        XCTAssertTrue(q.jump(to: "c"))
        XCTAssertEqual(q.current?.id, "c")
        XCTAssertFalse(q.jump(to: "zzz"))   // 不在は false・現在は不変
        XCTAssertEqual(q.current?.id, "c")
    }

    // MARK: - generic 化後の値の独立（要素型は Podcast ではなくテスト内の値型）

    private struct Track: Identifiable, Equatable {
        let id: String
        var label: String
    }

    // verifies: ios-check-07
    func testQueueIsIndependentOfCallerArraysReturnedArraysAndCopies() {
        // (a) 渡した配列・要素の元の変数を後から書き換えても、キューの中身は変わらない。
        var source = [Track(id: "a", label: "alpha"), Track(id: "b", label: "bravo"), Track(id: "c", label: "charlie")]
        var q = PlaybackQueue<Track>(items: source, currentIndex: 1)
        source[0].label = "changed"
        source.append(Track(id: "z", label: "Z"))
        XCTAssertEqual(q.items.map { $0.label }, ["alpha", "bravo", "charlie"])
        XCTAssertEqual(q.currentIndex, 1)

        var list = [Track(id: "d", label: "delta"), Track(id: "e", label: "echo")]
        q.setQueue(list, startAt: 0)
        list[0].label = "changed"
        list.removeAll()
        XCTAssertEqual(q.items, [Track(id: "d", label: "delta"), Track(id: "e", label: "echo")])
        XCTAssertEqual(q.currentIndex, 0)

        var single = Track(id: "s", label: "sierra")
        q.start(with: single)
        single.label = "changed"
        XCTAssertEqual(q.items, [Track(id: "s", label: "sierra")])

        var added = Track(id: "t", label: "tango")
        q.add(added)
        added.label = "changed"
        var next = Track(id: "u", label: "uniform")
        q.playNext(next)
        next.label = "changed"
        XCTAssertEqual(q.items, [
            Track(id: "s", label: "sierra"), Track(id: "u", label: "uniform"), Track(id: "t", label: "tango"),
        ])
        XCTAssertEqual(q.currentIndex, 0)

        // (b) 返った配列を書き換えても、次の読みは変わらない。
        var itemsRead = q.items
        itemsRead.removeAll()
        var upNextRead = q.upNext
        upNextRead[0].label = "changed"
        upNextRead.removeAll()
        XCTAssertEqual(q.items.map { $0.id }, ["s", "u", "t"])
        XCTAssertEqual(q.upNext, [Track(id: "u", label: "uniform"), Track(id: "t", label: "tango")])

        // (c) コピーを操作しても、元のキューは変わらない。不変条件（currentIndex は nil か範囲内）も保つ。
        let snapshot = q
        var copy = q
        copy.remove(id: "s")
        _ = copy.advance()
        XCTAssertEqual(q, snapshot)
        XCTAssertEqual(q.items.map { $0.id }, ["s", "u", "t"])
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertNotEqual(copy, snapshot)
        if let index = copy.currentIndex {
            XCTAssertTrue(copy.items.indices.contains(index))
        }

        // Equatable は items と currentIndex の両方で決まる。
        let sameItemsOtherIndex = PlaybackQueue<Track>(items: q.items, currentIndex: 2)
        XCTAssertNotEqual(sameItemsOtherIndex, q)
        XCTAssertEqual(PlaybackQueue<Track>(items: q.items, currentIndex: 0), q)
    }

}
