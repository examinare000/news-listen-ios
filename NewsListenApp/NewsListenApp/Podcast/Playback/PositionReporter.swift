//
//  PositionReporter.swift
//  NewsListenApp
//
//  再生位置と完聴をサーバーへ送る。周期は `positionChanged` と注入した時計で数える（タイマーを持たない）。
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

    private let updatePosition: (_ id: String, _ seconds: Double) async throws -> Episode
    private let markCompleted: (_ id: String) async throws -> Void
    private let onPositionSaved: (Episode) -> Void
    private let onCompletionRecorded: () async -> Void
    private let beginBackgroundTask: () -> (() -> Void)
    private let now: () -> Date

    private var phase = Phase.idle
    private var currentId: String?
    private var currentPosition = 0.0
    private var endedDuration = 0.0
    private var lastSentPosition: Double?
    private var hasSentCompletion = false
    private var periodStart: Date?

    init(updatePosition: @escaping (_ id: String, _ seconds: Double) async throws -> Episode,
         markCompleted: @escaping (_ id: String) async throws -> Void,
         onPositionSaved: @escaping (Episode) -> Void,
         onCompletionRecorded: @escaping () async -> Void,
         beginBackgroundTask: @escaping () -> (() -> Void),
         now: @escaping () -> Date = Date.init) {
        self.updatePosition = updatePosition
        self.markCompleted = markCompleted
        self.onPositionSaved = onPositionSaved
        self.onCompletionRecorded = onCompletionRecorded
        self.beginBackgroundTask = beginBackgroundTask
        self.now = now
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

    func listenCompleted(id: String) {
        guard !hasSentCompletion else { return }
        hasSentCompletion = true
        // Task が動く前に次の `loading` で基準が戻るので、書込む値はここで確定する。
        let finalPosition = completionPosition()
        let beginBackgroundTask = beginBackgroundTask
        let markCompleted = markCompleted
        let updatePosition = updatePosition
        let onPositionSaved = onPositionSaved
        let onCompletionRecorded = onCompletionRecorded
        Task { [weak self] in
            let finish = beginBackgroundTask()
            // `self?.apply(await …)` は self が nil だと引数ごと評価されないので、送信は先にローカルへ受ける。
            let completed = await Self.outcome { try await markCompleted(id) }
            self?.apply(completed)
            if let finalPosition {
                let saved = await Self.outcome {
                    let episode = try await updatePosition(id, finalPosition)
                    onPositionSaved(episode)
                }
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
            lastSentPosition = nil
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

    /// 同じ位置は再送しない。値の大小では止めない（巻き戻した位置も送る）。
    private func sendPosition(id: String, seconds: Double) {
        if lastSentPosition == seconds { return }
        lastSentPosition = seconds
        let updatePosition = updatePosition
        let onPositionSaved = onPositionSaved
        Task { [weak self] in
            let sent = await Self.outcome {
                let episode = try await updatePosition(id, seconds)
                onPositionSaved(episode)
            }
            self?.apply(sent)
        }
    }

    private enum Outcome {
        case succeeded
        case failed(ApiFailure)
        case ignored
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

    /// `lastSyncFailure` は最後に終わった送信の結果。`ApiFailure` 以外の error は無視する。
    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .succeeded: lastSyncFailure = nil
        case .failed(let failure): lastSyncFailure = failure
        case .ignored: break
        }
    }
}
