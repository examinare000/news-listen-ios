//
//  PositionRecords.swift
//  NewsListenApp
//
//  端末の位置の記録の持ち主。主体 × エピソードで最新 1 件・未送信の印・主体の束縛・回収・応答の取り込みを持つ。
//  束縛中の主体の分だけをメモリに写し、`unsent()` はその写しから返す（store は `bind` のときだけ読む）。
//

import Foundation

@MainActor
final class PositionRecords {
    private let store: PositionRecordStore
    private var boundSubject: SubjectKey?
    private var cache: [String: PositionRecord] = [:]
    /// エピソードごとに、一覧へ渡した応答の時刻の最大。プロセス内だけで持つ。
    private var highWater: [String: Date] = [:]
    /// 別の端末の値で記録を置き換えたエピソード。この端末が新しく記録するまで残る。プロセス内だけで持つ（永続しない）。
    private var absorbedIds: Set<String> = []

    nonisolated init(store: PositionRecordStore) {
        self.store = store
    }

    func bind(subject: SubjectKey?) {
        boundSubject = subject
        cache = [:]
        if let subject {
            for record in store.read(subject) { cache[record.episodeId] = record }
        }
        highWater = [:]
        absorbedIds = []
    }

    /// 束縛が無ければ何もしない（記録も送信もしない）。時刻・位置の大小で置換を拒まない（書いた順が最新）。
    @discardableResult
    func record(episodeId: String, seconds: Double, at: Date) -> PositionRecord? {
        guard let boundSubject else { return nil }
        let record = PositionRecord(
            subject: boundSubject, episodeId: episodeId, seconds: seconds, recordedAt: at, isSent: false)
        cache[episodeId] = record
        absorbedIds.remove(episodeId)
        persist()
        return record
    }

    /// 一覧・詳細で取得した値を取り込む。記録があり、取得した値が厳密に新しいときだけ置き換える（記録は作らない）。
    /// 再生中のセッションには触れない。
    func absorb(_ episodes: [Episode]) {
        guard let boundSubject else { return }
        var changed = false
        for case .playable(let playable) in episodes {
            if replaceIfNewer(by: playable, subject: boundSubject) { changed = true }
            raiseHighWater(playable.content.id, to: playable.serverRecordedAt)
        }
        if changed { persist() }
    }

    /// 端末の記録とサーバーの値のうち新しい方の秒。束縛が無ければ記録は空なのでサーバーの値。
    func candidate(for episode: PlayableEpisode) -> Double {
        PositionSyncRules.candidate(
            device: cache[episode.content.id],
            server: RecordedPosition(seconds: episode.serverPosition, recordedAt: episode.serverRecordedAt)
        ).seconds
    }

    /// 別の端末の値で置き換えた記録の秒。印が無ければ nil。
    func otherDevicePosition(for episodeId: String) -> Double? {
        guard absorbedIds.contains(episodeId) else { return nil }
        return cache[episodeId]?.seconds
    }

    func settle(_ record: PositionRecord, response: Episode) -> Episode? {
        guard record.subject == boundSubject else { return nil }
        var changed = false
        if let stored = cache[record.episodeId], stored.recordedAt == record.recordedAt, stored.seconds == record.seconds {
            cache[record.episodeId] = stored.markedSent()
            changed = true
        }
        var responseTime: Date?
        if case .playable(let playable) = response {
            responseTime = playable.serverRecordedAt
            if replaceIfNewer(by: playable, subject: record.subject) { changed = true }
        }
        if changed { persist() }
        guard !PositionSyncRules.isNewer(highWater[record.episodeId], than: responseTime) else { return nil }
        if let responseTime { highWater[record.episodeId] = responseTime }
        return response
    }

    /// 恒久の失敗: 送信済みの印を付け、記録は残す。
    func settleRejected(_ record: PositionRecord) {
        guard record.subject == boundSubject,
              let stored = cache[record.episodeId],
              stored.recordedAt == record.recordedAt, stored.seconds == record.seconds
        else { return }
        cache[record.episodeId] = stored.markedSent()
        persist()
    }

    func unsent() -> [PositionRecord] {
        cache.values
            .filter { !$0.isSent }
            .sorted { ($0.recordedAt, $0.episodeId) < ($1.recordedAt, $1.episodeId) }
    }

    func remove(subject: SubjectKey?) throws {
        if subject == boundSubject { cache = [:] }
        absorbedIds = []
        highWater = [:]
        if let subject { try store.removeSubject(subject) }
    }

    func reclaim(keeping: SubjectKey?) throws {
        if boundSubject != keeping { cache = [:] }
        absorbedIds = []
        highWater = [:]
        try store.reclaim(keeping)
    }

    /// 取得した値が記録より厳密に新しければ、送信済みの記録として置き換え、印を立てる。
    private func replaceIfNewer(by playable: PlayableEpisode, subject: SubjectKey) -> Bool {
        let id = playable.content.id
        let position = RecordedPosition(seconds: playable.serverPosition, recordedAt: playable.serverRecordedAt)
        guard PositionSyncRules.shouldAbsorb(position, over: cache[id]), let time = position.recordedAt else { return false }
        cache[id] = PositionRecord(subject: subject, episodeId: id, seconds: position.seconds, recordedAt: time, isSent: true)
        absorbedIds.insert(id)
        return true
    }

    /// 一覧へ渡した応答の時刻の最大を、新しいときだけ上げる（古い取得が新しい PATCH の応答の高水位を下げない）。
    private func raiseHighWater(_ id: String, to time: Date?) {
        guard let time, PositionSyncRules.isNewer(time, than: highWater[id]) else { return }
        highWater[id] = time
    }

    /// 保存に失敗しても、メモリ上の記録は残して送信を続ける（アプリが終了するまで送れる。ios-dec-133）。
    private func persist() {
        guard let boundSubject else { return }
        let records = cache.values.sorted { $0.episodeId < $1.episodeId }
        try? store.write(boundSubject, records)
    }
}
