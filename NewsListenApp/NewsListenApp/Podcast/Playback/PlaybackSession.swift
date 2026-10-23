//
//  PlaybackSession.swift
//  NewsListenApp
//
//  再生状態の union と、engine の駆動・engine 事象による遷移の決定を持つ。
//  `stop`・`fail` は遷移表の外の操作（分母 16 に数えない）。
//

import Foundation

enum SessionEvent: Equatable {
    case stateChanged(PlaybackState)
    case positionChanged(seconds: Double, duration: Double)
    case ended(episodeId: String)
    case interruption(InterruptionPhase)
}

@MainActor
final class PlaybackSession {
    private let engine: any AudioEngine
    private(set) var state: PlaybackState = .idle
    private var handlers: [(SessionEvent) -> Void] = []
    private var subscription: Task<Void, Never>?
    /// `paused` の間に届いた `failed`（外側の nil = 保留なし、内側 = 説明文）。
    private var pendingFailure: String??
    private var hasPendingEnded = false

    init(engine: any AudioEngine) {
        self.engine = engine
    }

    func observe(_ handler: @escaping (SessionEvent) -> Void) {
        handlers.append(handler)
    }

    @discardableResult
    func start(episode: PlayableEpisode, url: URL, resumePosition: Double, speed: Float) -> String? {
        switch state {
        case .loading, .playing, .buffering:
            releaseEngine()
            setState(.idle)
        case .paused:
            cancelSubscription()
        case .idle, .ended, .errored:
            break
        }
        clearPending()
        let effectiveSpeed = PlaybackConstants.speeds.contains(speed) ? speed : 1.0
        let warning = engine.load(url: url)
        let stream = engine.events
        subscription = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                self.apply(event)
            }
        }
        if resumePosition > 0 { engine.seek(to: resumePosition) }
        // AVPlayer の play() は速度を 1.0 に戻すので、速度は play() の後に掛ける。
        engine.play()
        engine.setRate(effectiveSpeed)
        setState(.loading(episode: episode, resumePosition: resumePosition, speed: effectiveSpeed))
        return warning
    }

    func play() {
        guard case .paused(let episode, let position, let duration, let speed) = state else { return }
        engine.setRate(speed)
        setState(.playing(episode: episode, position: position, duration: duration, speed: speed))
        if let failure = pendingFailure {
            clearPending()
            enterErrored(engineDescription: failure)
        } else if hasPendingEnded {
            clearPending()
            enterEnded()
        }
    }

    func pause() {
        switch state {
        case .loading(let episode, let resumePosition, let speed):
            engine.pause()
            setState(.paused(episode: episode, position: resumePosition,
                             duration: Double(episode.content.durationSeconds), speed: speed))
        case .playing(let episode, let position, let duration, let speed),
             .buffering(let episode, let position, let duration, let speed):
            engine.pause()
            setState(.paused(episode: episode, position: position, duration: duration, speed: speed))
        case .idle, .paused, .ended, .errored:
            break
        }
    }

    func seek(to seconds: Double) {
        switch state {
        case .loading(let episode, _, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: Double(episode.content.durationSeconds))
            engine.seek(to: target)
            setState(.loading(episode: episode, resumePosition: target, speed: speed))
        case .playing(let episode, _, let duration, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: duration)
            engine.seek(to: target)
            setState(.playing(episode: episode, position: target, duration: duration, speed: speed))
        case .buffering(let episode, _, let duration, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: duration)
            engine.seek(to: target)
            setState(.buffering(episode: episode, position: target, duration: duration, speed: speed))
        case .paused(let episode, _, let duration, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: duration)
            engine.seek(to: target)
            setState(.paused(episode: episode, position: target, duration: duration, speed: speed))
        case .idle, .ended, .errored:
            break
        }
    }

    func seekRelative(_ delta: Double) {
        guard PlaybackRules.isLoaded(state) else { return }
        seek(to: state.position + delta)
    }

    func setSpeed(_ speed: Float) {
        guard PlaybackConstants.speeds.contains(speed) else { return }
        switch state {
        case .loading(let episode, let resumePosition, _):
            engine.setRate(speed)
            setState(.loading(episode: episode, resumePosition: resumePosition, speed: speed))
        case .playing(let episode, let position, let duration, _):
            engine.setRate(speed)
            setState(.playing(episode: episode, position: position, duration: duration, speed: speed))
        case .buffering(let episode, let position, let duration, _):
            engine.setRate(speed)
            setState(.buffering(episode: episode, position: position, duration: duration, speed: speed))
        case .paused(let episode, let position, let duration, _):
            setState(.paused(episode: episode, position: position, duration: duration, speed: speed))
        case .idle, .ended, .errored:
            break
        }
    }

    func stop() {
        guard state != .idle else { return }
        releaseEngine()
        clearPending()
        setState(.idle)
    }

    func fail(episodeId: String, reason: PlaybackErrorReason) {
        if state != .idle { releaseEngine() }
        clearPending()
        setState(.errored(episodeId: episodeId, position: 0, reason: reason))
    }

    // MARK: - 内部

    private func emit(_ event: SessionEvent) {
        handlers.forEach { $0(event) }
    }

    private func setState(_ new: PlaybackState) {
        guard new != state else { return }
        state = new
        emit(.stateChanged(new))
    }

    private func cancelSubscription() {
        subscription?.cancel()
        subscription = nil
    }

    /// 読み込みを外す。購読 Task の cancel を engine.stop() より先に行う。
    private func releaseEngine() {
        cancelSubscription()
        engine.stop()
    }

    private func clearPending() {
        pendingFailure = nil
        hasPendingEnded = false
    }

    private func enterErrored(engineDescription: String?) {
        let episodeId = state.episodeId ?? ""
        let position = state.position
        releaseEngine()
        setState(.errored(episodeId: episodeId, position: position, reason: .engineFailed(description: engineDescription)))
    }

    private func enterEnded() {
        guard case .playing(let episode, _, let duration, _) = state else { return }
        releaseEngine()
        setState(.ended(episode: episode, duration: duration))
        emit(.ended(episodeId: episode.content.id))
    }

    /// `ready` と同じ進め方（`loading` → `paused` → `playing`）。`loading` でなければ何もしない。
    private func advanceFromLoading() {
        guard case .loading(let episode, let resumePosition, let speed) = state else { return }
        let duration = Double(episode.content.durationSeconds)
        setState(.paused(episode: episode, position: resumePosition, duration: duration, speed: speed))
        setState(.playing(episode: episode, position: resumePosition, duration: duration, speed: speed))
    }

    // MARK: - engine 事象

    private func apply(_ event: EngineEvent) {
        if state == .idle { return }
        switch event {
        case .ready:
            advanceFromLoading()
        case .resumed:
            applyResumed()
        case .buffering:
            if case .playing(let episode, let position, let duration, let speed) = state {
                setState(.buffering(episode: episode, position: position, duration: duration, speed: speed))
            }
        case .paused:
            if case .buffering(let episode, let position, let duration, let speed) = state {
                setState(.paused(episode: episode, position: position, duration: duration, speed: speed))
            }
        case .ended:
            applyEngineEnded()
        case .failed(let description):
            applyEngineFailed(description)
        case .timeUpdate(let seconds, let reportedDuration):
            applyTimeUpdate(seconds: seconds, reportedDuration: reportedDuration)
        case .interrupted:
            applyInterrupted()
        case .interruptionEnded(let shouldResume):
            emit(.interruption(.ended(shouldResume: shouldResume)))
        case .outputDeviceLost:
            pauseIfRunning()
        }
    }

    private func applyResumed() {
        if case .buffering(let episode, let position, let duration, let speed) = state {
            setState(.playing(episode: episode, position: position, duration: duration, speed: speed))
        } else {
            advanceFromLoading()
        }
    }

    private func applyEngineEnded() {
        switch state {
        case .loading:
            advanceFromLoading()
            enterEnded()
        case .playing:
            enterEnded()
        case .buffering(let episode, let position, let duration, let speed):
            setState(.playing(episode: episode, position: position, duration: duration, speed: speed))
            enterEnded()
        case .paused:
            hasPendingEnded = true
        case .idle, .ended, .errored:
            break
        }
    }

    private func applyEngineFailed(_ description: String?) {
        switch state {
        case .loading, .playing, .buffering:
            enterErrored(engineDescription: description)
        case .paused:
            pendingFailure = .some(description)
        case .idle, .ended, .errored:
            break
        }
    }

    private func applyTimeUpdate(seconds: Double, reportedDuration: Double) {
        switch state {
        case .playing(let episode, _, let duration, let speed):
            let newDuration = reportedDuration > 0 ? reportedDuration : duration
            state = .playing(episode: episode, position: seconds, duration: newDuration, speed: speed)
            emit(.positionChanged(seconds: seconds, duration: newDuration))
        case .buffering(let episode, _, let duration, let speed):
            let newDuration = reportedDuration > 0 ? reportedDuration : duration
            state = .buffering(episode: episode, position: seconds, duration: newDuration, speed: speed)
            emit(.positionChanged(seconds: seconds, duration: newDuration))
        case .paused(let episode, _, let duration, let speed):
            let newDuration = reportedDuration > 0 ? reportedDuration : duration
            state = .paused(episode: episode, position: seconds, duration: newDuration, speed: speed)
            emit(.positionChanged(seconds: seconds, duration: newDuration))
        case .idle, .loading, .ended, .errored:
            break
        }
    }

    private func applyInterrupted() {
        switch state {
        case .loading, .playing, .buffering:
            pause()
            emit(.interruption(.began(wasPlaying: true)))
        case .paused:
            emit(.interruption(.began(wasPlaying: false)))
        case .idle, .ended, .errored:
            break
        }
    }

    private func pauseIfRunning() {
        switch state {
        case .loading, .playing, .buffering:
            pause()
        case .idle, .paused, .ended, .errored:
            break
        }
    }
}
