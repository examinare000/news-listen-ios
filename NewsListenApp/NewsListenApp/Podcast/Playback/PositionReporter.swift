//
//  PositionReporter.swift
//  NewsListenApp
//
//  再生位置と完聴をサーバーへ送る。位置は端末に記録（`PositionRecords`）してから送り、送れなかった分は
//  起動・接続復帰・次の新しい送信で再送する。周期は `positionChanged` と注入した時計で数える（タイマーを持たない）。
//

import Foundation
import Combine

@MainActor
final class PositionReporter: ObservableObject {
    @Published private(set) var lastSyncFailure: ApiFailure?

    private static let periodSeconds: TimeInterval = 15

    private enum Phase {
        case idle
        case loading
        case playing
        case buffering
        case paused
        case ended
        case errored
    }

    /// 送信中（応答を待つ・これから送る）の記録の key。同じ key の記録を重ねて送らない。
    /// 各 key の印の持ち主は高々 1 つ（直接の送信か、再送の走査の 1 項目）で、持ち主はどの経路でも必ず外す。
    private struct InFlightKey: Hashable {
        fileprivate let episodeId: String
        fileprivate let recordedAt: Date

        fileprivate init(_ record: PositionRecord) {
            episodeId = record.episodeId
            recordedAt = record.recordedAt
        }
    }

    private let updatePosition: (_ id: String, _ seconds: Double, _ recordedAt: Date) async throws -> Episode
    private let markCompleted: (_ id: String) async throws -> Void
    private let onPositionSaved: (Episode) -> Void
    private let onCompletionRecorded: () async -> Void
    private let beginBackgroundTask: () -> (() -> Void)
    private let records: PositionRecords
    private let now: () -> Date

    private var phase = Phase.idle
    private var currentId: String?
    private var currentPosition = 0.0
    private var endedDuration = 0.0
    private var lastRecordedPosition: Double?
    private var hasSentCompletion = false
    private var periodStart: Date?
    private var inFlight: Set<InFlightKey> = []
    private var connectivitySubscription: AnyCancellable?

    init(updatePosition: @escaping (_ id: String, _ seconds: Double, _ recordedAt: Date) async throws -> Episode,
         markCompleted: @escaping (_ id: String) async throws -> Void,
         onPositionSaved: @escaping (Episode) -> Void,
         onCompletionRecorded: @escaping () async -> Void,
         beginBackgroundTask: @escaping () -> (() -> Void),
         records: PositionRecords,
         connectivity: AnyPublisher<Bool, Never>,
         now: @escaping () -> Date = Date.init) {
        self.updatePosition = updatePosition
        self.markCompleted = markCompleted
        self.onPositionSaved = onPositionSaved
        self.onCompletionRecorded = onCompletionRecorded
        self.beginBackgroundTask = beginBackgroundTask
        self.records = records
        self.now = now
        // 最初の値は購読時点の状態なので捨てる（起動時の再送は `ContentView` が担う）。
        connectivitySubscription = connectivity
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.resendUnsent() }
            }
    }

    func attach(_ session: PlaybackSession) {
        session.observe { [weak self] event in
            self?.handle(event)
        }
    }

    func flush() {
        guard phase == .playing || phase == .buffering || phase == .paused, let id = currentId else { return }
        sendPosition(id: id, seconds: currentPosition)
    }

    /// 今の位置を今の時刻で記録して送る。同じ位置でも記録する（取り込みで置き換わった記録を、この端末の位置で上書きするため）。
    func recordNow() {
        guard phase == .playing || phase == .buffering || phase == .paused, let id = currentId else { return }
        lastRecordedPosition = nil
        sendPosition(id: id, seconds: currentPosition)
    }

    /// 呼ばれた時点の未送信（送信中を除く）を、1 件ずつ順に送る。走査は 1 回で、再送が再送を起動しない。
    func resendUnsent() {
        let snapshot = records.unsent().filter { !inFlight.contains(InFlightKey($0)) }
        guard !snapshot.isEmpty else { return }
        for record in snapshot { inFlight.insert(InFlightKey(record)) }
        let sender = sender
        let records = records
        Task { [weak self] in
            for (index, record) in snapshot.enumerated() {
                // 走査の間に置き換わった・送信済みになった記録は送らない（新しい記録は次の契機が送る）。
                guard records.unsent().contains(record) else {
                    self?.release(record)
                    continue
                }
                let outcome = await Self.deliver(record, with: sender)
                self?.release(record)
                if case .skipped = outcome {
                    // 主体が変わった。残りの旧主体の記録は送らない。
                    for rest in snapshot[(index + 1)...] { self?.release(rest) }
                    return
                }
                self?.apply(outcome)
            }
        }
    }

    func listenCompleted(id: String) {
        guard !hasSentCompletion else { return }
        hasSentCompletion = true
        // Task が動く前に次の `loading` で基準が戻るので、書く値と時刻はここで確定する。
        var scheduled: PositionRecord?
        if let finalPosition = completionPosition(),
           let record = records.record(episodeId: id, seconds: finalPosition, at: now()),
           inFlight.insert(InFlightKey(record)).inserted {
            scheduled = record
        }
        let beginBackgroundTask = beginBackgroundTask
        let markCompleted = markCompleted
        let onCompletionRecorded = onCompletionRecorded
        let sender = sender
        Task { [weak self] in
            let finish = beginBackgroundTask()
            // `self?.apply(await …)` は self が nil だと引数ごと評価されないので、送信は先にローカルへ受ける。
            let completed = await Self.outcome { try await markCompleted(id) }
            self?.apply(completed)
            if let scheduled {
                let delivery = Task { await Self.deliver(scheduled, with: sender) }
                // 位置の送信を始めた後に、残りの未送信を 1 回再送する（送信中の key は走査に入らない）。
                self?.resendUnsent()
                let saved = await delivery.value
                self?.release(scheduled)
                self?.apply(saved)
            }
            await onCompletionRecorded()
            finish()
        }
    }

    // MARK: - 内部

    private func completionPosition() -> Double? {
        if endedDuration > 0 { return endedDuration }
        return currentPosition > 0 ? currentPosition : nil
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let state):
            handleStateChange(state)
        case .positionChanged(let seconds, _):
            currentPosition = seconds
            sendIfPeriodElapsed()
        case .ended, .interruption:
            break
        }
    }

    private func handleStateChange(_ state: PlaybackState) {
        switch state {
        case .loading(let episode, let resumePosition, _):
            phase = .loading
            currentId = episode.content.id
            currentPosition = resumePosition
            endedDuration = 0
            lastRecordedPosition = nil
            hasSentCompletion = false
        case .playing(_, let position, _, _):
            if phase == .paused || phase == .loading { periodStart = now() }
            currentPosition = position
            phase = .playing
        case .buffering(_, let position, _, _):
            currentPosition = position
            phase = .buffering
        case .paused(_, let position, _, _):
            if phase == .playing || phase == .buffering, let id = currentId {
                sendPosition(id: id, seconds: position)
            }
            currentPosition = position
            phase = .paused
        case .ended(_, let duration):
            endedDuration = duration
            phase = .ended
        case .errored:
            phase = .errored
        case .idle:
            phase = .idle
        }
    }

    private func sendIfPeriodElapsed() {
        guard phase == .playing, let start = periodStart, let id = currentId else { return }
        let current = now()
        guard current.timeIntervalSince(start) >= Self.periodSeconds else { return }
        sendPosition(id: id, seconds: currentPosition)
        periodStart = current
    }

    /// 同じ位置は記録しない。値の大小では止めない（巻き戻した位置も記録する）。束縛が無いときは記録も送信もしない。
    private func sendPosition(id: String, seconds: Double) {
        if lastRecordedPosition == seconds { return }
        guard let record = records.record(episodeId: id, seconds: seconds, at: now()) else { return }
        lastRecordedPosition = seconds
        // 同じ key（同じミリ秒の別の位置）が送信中なら送らない。記録は未送信のまま残り、次の契機で送る。
        guard inFlight.insert(InFlightKey(record)).inserted else { return }
        let sender = sender
        Task { [weak self] in
            let outcome = await Self.deliver(record, with: sender)
            self?.release(record)
            self?.apply(outcome)
        }
        resendUnsent()
    }

    private func release(_ record: PositionRecord) {
        inFlight.remove(InFlightKey(record))
    }

    /// 送信に必要な部品。Reporter が解放された後も送信と後始末を完了できるよう、`self` を含めない。
    private struct Sender {
        fileprivate let updatePosition: (_ id: String, _ seconds: Double, _ recordedAt: Date) async throws -> Episode
        fileprivate let onPositionSaved: (Episode) -> Void
        fileprivate let records: PositionRecords
    }

    private var sender: Sender {
        Sender(updatePosition: updatePosition, onPositionSaved: onPositionSaved, records: records)
    }

    private enum Outcome {
        case succeeded
        case failed(ApiFailure)
        case ignored
        /// 送信の直前に、記録の主体が束縛中の主体でなくなっていた。送っていない。
        case skipped
    }

    private static func outcome(_ operation: () async throws -> Void) async -> Outcome {
        do {
            try await operation()
            return .succeeded
        } catch let failure as ApiFailure {
            return .failed(failure)
        } catch {
            return .ignored
        }
    }

    /// 1 件の送信。送信の直前に主体を照合し、結果は 1 回の同期処理（応答の取り込み → 呼出元が印を外す → `apply`）で扱う。
    private static func deliver(_ record: PositionRecord, with sender: Sender) async -> Outcome {
        guard sender.records.unsent().contains(where: { $0.subject == record.subject }) else { return .skipped }
        do {
            let episode = try await sender.updatePosition(record.episodeId, record.seconds, record.recordedAt)
            if let saved = sender.records.settle(record, response: episode) {
                sender.onPositionSaved(saved)
            }
            return .succeeded
        } catch let failure as ApiFailure {
            if failure == .unknown(status: 404) || failure == .unknown(status: 422) {
                sender.records.settleRejected(record)
            }
            return .failed(failure)
        } catch {
            return .ignored
        }
    }

    /// `lastSyncFailure` は最後に終わった送信の結果。`ApiFailure` 以外の error は無視する。
    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .succeeded: lastSyncFailure = nil
        case .failed(let failure): lastSyncFailure = failure
        case .ignored, .skipped: break
        }
    }
}
