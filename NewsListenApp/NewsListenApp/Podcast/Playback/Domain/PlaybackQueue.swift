//
//  PlaybackQueue.swift
//  NewsListenApp
//
//  再生キュー（プレイリスト）の純粋な状態モデル（issue #81）。
//  AVPlayer に依存しないため、自動次再生・空キュー停止・並べ替え等をユニットテストできる。
//

import Foundation

/// 順序付きの再生キュー。現在再生中の位置（`currentIndex`）と待機列を管理する。
///
/// プレイヤー非依存（副作用なし）。`PodcastViewModel` が再生終了イベントで `advance()` を呼び、
/// 返った要素を再生する（nil なら停止）。
struct PlaybackQueue<Item: Identifiable> where Item.ID == String {
    /// キュー全体（再生済み + 現在 + 待機）。
    private(set) var items: [Item]
    /// 現在再生中の位置。未再生・空のときは nil。
    private(set) var currentIndex: Int?

    init(items: [Item] = [], currentIndex: Int? = nil) {
        let (unique, index) = Self.deduplicated(items, currentIndex: Self.clamped(currentIndex, count: items.count))
        self.items = unique
        self.currentIndex = index
    }

    /// 現在再生中の要素（なければ nil）。
    var current: Item? {
        guard let i = currentIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    /// 再生待ち（現在より後ろの要素）。
    var upNext: [Item] {
        guard let i = currentIndex else { return items }
        let start = min(i + 1, items.count)
        return Array(items[start...])
    }

    /// キューが空か。
    var isEmpty: Bool { items.isEmpty }

    /// 単一エピソードで開始する（既存キューを置き換える）。
    mutating func start(with item: Item) {
        items = [item]
        currentIndex = 0
    }

    /// 一覧を指定位置から再生する（「ここから連続再生」）。
    mutating func setQueue(_ newItems: [Item], startAt index: Int) {
        (items, currentIndex) = Self.deduplicated(newItems, currentIndex: Self.clamped(index, count: newItems.count))
    }

    /// 範囲外は端へ丸める。空なら nil。
    private static func clamped(_ index: Int?, count: Int) -> Int? {
        guard count > 0, let index else { return nil }
        return max(0, min(index, count - 1))
    }

    /// 同じ id は先勝ちで 1 つにする。`currentIndex` は元の入力で指していた要素の id を追う。
    private static func deduplicated(_ items: [Item], currentIndex: Int?) -> (items: [Item], currentIndex: Int?) {
        let currentId = currentIndex.map { items[$0].id }
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        return (unique, currentId.flatMap { id in unique.firstIndex { $0.id == id } })
    }

    /// 末尾に追加する（既に含まれていれば無視＝重複防止）。
    mutating func add(_ item: Item) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
    }

    /// 現在の次に挿入する（「次に再生」）。既存の重複（現在再生中を除く）は取り除いてから挿入する。
    mutating func playNext(_ item: Item) {
        let currentId = current?.id
        if item.id == currentId { return }   // 再生中の自分自身は何もしない
        items.removeAll { $0.id == item.id }
        // 削除で currentIndex がずれうるため現在 id から再計算する。
        if let cid = currentId {
            currentIndex = items.firstIndex { $0.id == cid }
        }
        let insertAt = currentIndex.map { $0 + 1 } ?? 0
        items.insert(item, at: min(insertAt, items.count))
    }

    /// 指定 id が既にキューにあればそれを現在位置にする（「キュー内の別エピソードを今すぐ再生」）。
    /// 見つかれば true。無ければキューは変更せず false。
    mutating func jump(to id: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        currentIndex = idx
        return true
    }

    /// 次のエピソードへ進む。次があれば `currentIndex` を進めて返す。無ければ nil（停止）。
    mutating func advance() -> Item? {
        guard let i = currentIndex else {
            // 未再生なら先頭から始める。
            guard !items.isEmpty else { return nil }
            currentIndex = 0
            return items[0]
        }
        let next = i + 1
        guard next < items.count else { return nil }   // 末尾に到達 → 停止
        currentIndex = next
        return items[next]
    }

    /// 指定 id をキューから削除する。`currentIndex` は現在のアイテムを追従して調整する。
    mutating func remove(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: idx)
        guard let cur = currentIndex else { return }
        if items.isEmpty {
            currentIndex = nil
        } else if idx < cur {
            currentIndex = cur - 1
        } else if idx == cur {
            // 現在を削除: 同じ位置（=次の要素）を現在にする。末尾だったらクランプ。
            currentIndex = min(cur, items.count - 1)
        }
        // idx > cur は現在位置に影響しない。
    }

    /// 待機列（`upNext`）を SwiftUI の `onMove(fromOffsets:toOffset:)` 規約で並べ替える。
    /// 現在より前（再生済み・現在）は動かさないため `currentIndex` は不変。
    /// SwiftUI に依存しないよう、`Array.move` 相当を自前で実装する（純粋モデルを保つ）。
    mutating func reorderUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        if let cur = currentIndex {
            let base = cur + 1
            guard base < items.count else { return }
            var up = Array(items[base...])
            Self.applyMove(to: &up, fromOffsets: source, toOffset: destination)
            items.replaceSubrange(base..<items.count, with: up)
        } else {
            Self.applyMove(to: &items, fromOffsets: source, toOffset: destination)
        }
    }

    /// `Array.move(fromOffsets:toOffset:)`（SwiftUI 提供）と同じ規約での移動を自前実装する。
    private static func applyMove(to array: inout [Item], fromOffsets source: IndexSet, toOffset destination: Int) {
        // shared-playback-spec §2.7: 範囲外の moveUpNext はクランプせず no-op。
        guard !source.isEmpty, source.allSatisfy({ array.indices.contains($0) }), (0...array.count).contains(destination) else { return }
        let moving = source.sorted().map { array[$0] }
        for index in source.sorted(by: >) {
            array.remove(at: index)
        }
        // destination より前から取り除いた分だけ挿入位置を前倒しする（SwiftUI 規約）。
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertAt = max(0, min(destination - removedBeforeDestination, array.count))
        array.insert(contentsOf: moving, at: insertAt)
    }
}

extension PlaybackQueue: Equatable where Item: Equatable {}
