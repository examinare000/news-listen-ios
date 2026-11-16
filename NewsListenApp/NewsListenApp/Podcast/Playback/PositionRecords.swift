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
    }

    /// 束縛が無ければ何もしない（記録も送信もしない）。時刻・位置の大小で置換を拒まない（書いた順が最新）。
    @discardableResult
    func record(episodeId: String, seconds: Double, at: Date) -> PositionRecord? {
        guard let boundSubject else { return nil }
        let record = PositionRecord(
            subject: boundSubject, episodeId: episodeId, seconds: seconds, recordedAt: at, isSent: false)
        cache[episodeId] = record
        persist()
        return record
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
            let position = RecordedPosition(seconds: playable.serverPosition, recordedAt: playable.serverRecordedAt)
            if PositionSyncRules.shouldAbsorb(position, over: cache[record.episodeId]), let time = position.recordedAt {
                cache[record.episodeId] = PositionRecord(
                    subject: record.subject, episodeId: record.episodeId, seconds: position.seconds,
                    recordedAt: time, isSent: true)
                changed = true
            }
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
        highWater = [:]
        if let subject { try store.removeSubject(subject) }
    }

    func reclaim(keeping: SubjectKey?) throws {
        if boundSubject != keeping { cache = [:] }
        highWater = [:]
        try store.reclaim(keeping)
    }

    /// 保存に失敗しても、メモリ上の記録は残して送信を続ける（アプリが終了するまで送れる。ios-dec-133）。
    private func persist() {
        guard let boundSubject else { return }
        let records = cache.values.sorted { $0.episodeId < $1.episodeId }
        try? store.write(boundSubject, records)
    }
}
