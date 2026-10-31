import XCTest
import SwiftUI
@testable import NewsListenApp

/// 再生キューの契約のうち、重複 id の除去（ios-contract-14）と待機列の複数要素の並べ替え（ios-contract-15）を固定する。
///
/// 既存の `PlaybackQueueTests` と同じく adapter 層の `PlaybackQueue<Podcast>` で書く。
/// domain 型だけを参照すると、domain テストの登録検査が未登録のファイルとして検出するため。
final class PlaybackQueueIosContractTests: XCTestCase {

    /// `title` に出現位置を入れ、同じ id の別要素を区別できるようにする（先勝ちの検証用）。
    private func podcast(_ id: String, title: String = "") -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://example.com/\(id).wav", title: title,
            japaneseIntroText: "intro",
            durationSeconds: 120, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
    }

    private func ids(_ queue: PlaybackQueue<Podcast>) -> [String] {
        queue.items.map(\.id)
    }

    /// id 3 種・長さ 0〜5 の全組合せ（364 通り）。
    private func allSequences() -> [[String]] {
        var result: [[String]] = [[]]
        var frontier: [[String]] = [[]]
        for _ in 1...5 {
            frontier = frontier.flatMap { prefix in ["a", "b", "c"].map { prefix + [$0] } }
            result += frontier
        }
        return result
    }

    private func inputs(_ sequence: [String]) -> [Podcast] {
        sequence.enumerated().map { podcast($1, title: "\($1)#\($0)") }
    }

    /// 重複除去とは独立に、元の入力だけから期待値を組む。
    private func expected(_ sequence: [String], index: Int?) -> (items: [String], titles: [String], currentId: String?) {
        var seen = Set<String>()
        var keptIds: [String] = []
        var keptTitles: [String] = []
        for (offset, id) in sequence.enumerated() where seen.insert(id).inserted {
            keptIds.append(id)
            keptTitles.append("\(id)#\(offset)")
        }
        guard !sequence.isEmpty, let index else { return (keptIds, keptTitles, nil) }
        let clamped = max(0, min(index, sequence.count - 1))
        return (keptIds, keptTitles, sequence[clamped])
    }

    // verifies: ios-contract-14
    // kills: 重複を取り除かない／後勝ちにする／除去後の配列で clamp して現在の要素が変わる
    func testIosTest093_dedupPropertyKeepsFirstOccurrence() {
        let sequences = allSequences()
        XCTAssertEqual(sequences.count, 364, "Given: 列挙が空振りしていない")
        var duplicated = 0

        for sequence in sequences {
            if Set(sequence).count < sequence.count { duplicated += 1 }
            let items = inputs(sequence)
            for index in [Int?.none] + (-1...sequence.count + 1).map({ Int?.some($0) }) {
                let want = expected(sequence, index: index)
                let label = "\(sequence) index=\(String(describing: index))"

                let viaInit = PlaybackQueue<Podcast>(items: items, currentIndex: index)
                XCTAssertEqual(ids(viaInit), want.items, "init \(label)")
                XCTAssertEqual(viaInit.items.map(\.title), want.titles, "init 先勝ち \(label)")
                XCTAssertEqual(viaInit.current?.id, want.currentId, "init 現在 \(label)")
                XCTAssertEqual(Set(ids(viaInit)).count, viaInit.items.count, "init id 一意 \(label)")

                // setQueue は index が非 optional。nil 指定の行は init だけが持つ。
                guard let index else { continue }
                var viaSet = PlaybackQueue<Podcast>()
                viaSet.setQueue(items, startAt: index)
                XCTAssertEqual(ids(viaSet), want.items, "setQueue \(label)")
                XCTAssertEqual(viaSet.items.map(\.title), want.titles, "setQueue 先勝ち \(label)")
                XCTAssertEqual(viaSet.current?.id, want.currentId, "setQueue 現在 \(label)")
                XCTAssertEqual(Set(ids(viaSet)).count, viaSet.items.count, "setQueue id 一意 \(label)")
            }
        }
        XCTAssertGreaterThan(duplicated, 0, "Given: 重複を含む入力が実際に走った")
    }

    // verifies: ios-contract-14
    func testDedupExpectationTableKeepsFirstOccurrenceAndFollowsId() {
        var set = PlaybackQueue<Podcast>()
        set.setQueue([podcast("a"), podcast("b"), podcast("a")], startAt: 2)
        XCTAssertEqual(ids(set), ["a", "b"])
        XCTAssertEqual(set.current?.id, "a")
        XCTAssertEqual(set.currentIndex, 0)

        let viaInit = PlaybackQueue<Podcast>(items: [podcast("a"), podcast("b"), podcast("a")], currentIndex: 2)
        XCTAssertEqual(ids(viaInit), ["a", "b"])
        XCTAssertEqual(viaInit.current?.id, "a")
        XCTAssertEqual(viaInit.currentIndex, 0)

        let noCurrent = PlaybackQueue<Podcast>(items: [podcast("a"), podcast("a")], currentIndex: nil)
        XCTAssertEqual(ids(noCurrent), ["a"])
        XCTAssertNil(noCurrent.currentIndex)

        var empty = PlaybackQueue<Podcast>()
        empty.setQueue([], startAt: 0)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.currentIndex)
    }

    // verifies: ios-contract-14
    func testSharedQueue33_setQueueClampsOnOriginalInputThenFollowsId() {
        var queue = PlaybackQueue<Podcast>()
        queue.setQueue([podcast("a"), podcast("b"), podcast("a"), podcast("c")], startAt: 2)

        XCTAssertEqual(ids(queue), ["a", "b", "c"])
        XCTAssertEqual(queue.current?.id, "a", "元の入力の 2 番目（a）を指し続ける")
        XCTAssertEqual(queue.currentIndex, 0)
    }

    // MARK: - 待機列の複数要素の並べ替え

    // verifies: ios-contract-15
    // kills: 複数要素を 1 つずつ動かして順序が崩れる／destination の補正を誤る／範囲外で状態を変える
    func testIosTest094_reorderUpNextMultipleOffsetsMatchesArrayMove() {
        func makeQueue() -> PlaybackQueue<Podcast> {
            PlaybackQueue<Podcast>(items: ["a", "b", "c", "d", "e"].map { podcast($0) }, currentIndex: 0)
        }
        let original = ["b", "c", "d", "e"]

        let valid: [(source: IndexSet, destination: Int, want: [String])] = [
            ([0, 2], 4, ["c", "e", "b", "d"]),
            ([1, 3], 0, ["c", "e", "b", "d"]),
            ([0, 1], 2, ["b", "c", "d", "e"]),
        ]
        for row in valid {
            var queue = makeQueue()
            queue.reorderUpNext(fromOffsets: row.source, toOffset: row.destination)
            XCTAssertEqual(queue.upNext.map(\.id), row.want, "\(row.source) → \(row.destination)")

            var swiftUI = original
            swiftUI.move(fromOffsets: row.source, toOffset: row.destination)
            XCTAssertEqual(queue.upNext.map(\.id), swiftUI, "SwiftUI の move と一致 \(row.source) → \(row.destination)")
            XCTAssertEqual(queue.currentIndex, 0)
            XCTAssertEqual(queue.current?.id, "a")
        }

        // 範囲外は Array.move を呼ばない（範囲外での挙動は未検証のため）。
        let outOfRange: [(source: IndexSet, destination: Int)] = [([0, 4], 0), ([0], 5)]
        for row in outOfRange {
            var queue = makeQueue()
            queue.reorderUpNext(fromOffsets: row.source, toOffset: row.destination)
            XCTAssertEqual(queue.upNext.map(\.id), original, "範囲外は無変更 \(row.source) → \(row.destination)")
            XCTAssertEqual(queue.currentIndex, 0)
            XCTAssertEqual(queue.current?.id, "a")
        }
    }
}
