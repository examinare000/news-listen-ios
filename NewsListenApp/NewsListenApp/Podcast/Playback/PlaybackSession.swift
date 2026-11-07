//
//  PlaybackSession.swift
//  NewsListenApp
//
//  engine の駆動と、`PlaybackTransition`（domain）が決めた効果の実行を持つ。
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
    /// `paused` の間に届いた `failed`・`ended` の保留。
    private var pending = PendingEngineOutcome.none

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
        dispatch(.play)
    }

    func pause() {
        dispatch(.pause)
    }

    func seek(to seconds: Double) {
        dispatch(.seek(seconds))
    }

    func seekRelative(_ delta: Double) {
        dispatch(.seekRelative(delta))
    }

    func setSpeed(_ speed: Float) {
        dispatch(.setSpeed(speed))
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
        pending = .none
    }

    // MARK: - 遷移の決定の呼出しと効果の実行

    /// 純関数に決定を委ね、結果の保留を先に格納してから効果を順に実行する。
    /// 結果の `state` は代入しない（通知を受けた handler が先に操作を呼びうるため、効果の側で進める）。
    private func dispatch(_ input: PlaybackInput) {
        let result = PlaybackTransition.next(state: state, pending: pending, input: input)
        pending = result.pending
        for effect in result.effects {
            execute(effect)
        }
    }

    private func execute(_ effect: PlaybackEffect) {
        switch effect {
        case .engine(let command):
            run(command)
        case .updateState(let new):
            state = new
        case .notify(let output):
            if case .stateChanged(let new) = output { state = new }
            emit(sessionEvent(output))
        }
    }

    private func run(_ command: EngineCommand) {
        switch command {
        case .pause:
            engine.pause()
        case .seek(let seconds):
            engine.seek(to: seconds)
        case .setRate(let rate):
            engine.setRate(rate)
        case .unload:
            releaseEngine()
        }
    }

    private func sessionEvent(_ output: PlaybackOutput) -> SessionEvent {
        switch output {
        case .stateChanged(let new):
            return .stateChanged(new)
        case .positionChanged(let seconds, let duration):
            return .positionChanged(seconds: seconds, duration: duration)
        case .ended(let episodeId):
            return .ended(episodeId: episodeId)
        case .interruption(let phase):
            return .interruption(phase)
        }
    }

    // MARK: - engine 事象

    private func apply(_ event: EngineEvent) {
        dispatch(input(for: event))
    }

    private func input(for event: EngineEvent) -> PlaybackInput {
        switch event {
        case .ready: return .engineReady
        case .resumed: return .engineResumed
        case .buffering: return .engineBuffering
        case .paused: return .enginePaused
        case .ended: return .engineEnded
        case .failed(let description): return .engineFailed(description)
        case .timeUpdate(let seconds, let duration): return .engineTimeUpdate(seconds, duration)
        case .interrupted: return .engineInterrupted
        case .interruptionEnded(let shouldResume): return .engineInterruptionEnded(shouldResume)
        case .outputDeviceLost: return .engineOutputDeviceLost
        }
    }
}
