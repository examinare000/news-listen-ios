//
//  PlaybackTransition.swift
//  NewsListenApp
//
//  再生の遷移の決定（domain の純関数）。状態・保留・入力から、次の状態・保留・
//  順序つきの効果の列を決める。効果の実行は `PlaybackSession`（application）が行う。
//

import Foundation

enum PlaybackInput: Equatable {
    case play, pause, seek(Double), seekRelative(Double), setSpeed(Float)
    case engineReady, engineResumed, engineBuffering, enginePaused, engineEnded
    case engineFailed(String?)
    case engineTimeUpdate(Double, Double)
    case engineInterrupted
    case engineInterruptionEnded(Bool)
    case engineOutputDeviceLost
}

enum EngineCommand: Equatable { case pause, seek(Double), setRate(Float), unload }

enum PlaybackOutput: Equatable { case stateChanged(PlaybackState), positionChanged(seconds: Double, duration: Double), ended(episodeId: String), interruption(InterruptionPhase) }

enum PlaybackEffect: Equatable { case engine(EngineCommand), updateState(PlaybackState), notify(PlaybackOutput) }

struct PendingEngineOutcome: Equatable {
    let failed: String??
    let ended: Bool
    static let none = PendingEngineOutcome(failed: nil, ended: false)
}

struct PlaybackTransitionResult: Equatable { let state: PlaybackState; let pending: PendingEngineOutcome; let effects: [PlaybackEffect] }

enum PlaybackTransition {
    static func next(state: PlaybackState, pending: PendingEngineOutcome, input: PlaybackInput) -> PlaybackTransitionResult {
        var draft = Draft(state: state, pending: pending)
        draft.apply(input)
        return PlaybackTransitionResult(state: draft.state, pending: draft.pending, effects: draft.effects)
    }
}

/// 効果を積みながら状態を進める作業用の値。`stateChanged` は直前と異なるときだけ積む。
private struct Draft {
    var state: PlaybackState
    var pending: PendingEngineOutcome
    var effects: [PlaybackEffect] = []

    mutating func apply(_ input: PlaybackInput) {
        if state == .idle { return }
        switch input {
        case .play:
            play()
        case .pause:
            pauseIfRunning()
        case .seek(let seconds):
            seek(to: seconds)
        case .seekRelative(let delta):
            guard PlaybackRules.isLoaded(state) else { return }
            seek(to: state.position + delta)
        case .setSpeed(let speed):
            setSpeed(speed)
        case .engineReady:
            advanceFromLoading()
        case .engineResumed:
            if case .buffering(let episode, let position, let duration, let speed) = state {
                commit(.playing(episode: episode, position: position, duration: duration, speed: speed))
            } else {
                advanceFromLoading()
            }
        case .engineBuffering:
            if case .playing(let episode, let position, let duration, let speed) = state {
                commit(.buffering(episode: episode, position: position, duration: duration, speed: speed))
            }
        case .enginePaused:
            if case .buffering(let episode, let position, let duration, let speed) = state {
                commit(.paused(episode: episode, position: position, duration: duration, speed: speed))
            }
        case .engineEnded:
            engineEnded()
        case .engineFailed(let description):
            engineFailed(description)
        case .engineTimeUpdate(let seconds, let reportedDuration):
            timeUpdate(seconds: seconds, reportedDuration: reportedDuration)
        case .engineInterrupted:
            interrupted()
        case .engineInterruptionEnded(let shouldResume):
            notify(.interruption(.ended(shouldResume: shouldResume)))
        case .engineOutputDeviceLost:
            pauseIfRunning()
        }
    }

    // MARK: - 効果の積み方

    private mutating func command(_ command: EngineCommand) {
        effects.append(.engine(command))
    }

    private mutating func notify(_ output: PlaybackOutput) {
        effects.append(.notify(output))
    }

    private mutating func commit(_ new: PlaybackState) {
        guard new != state else { return }
        state = new
        notify(.stateChanged(new))
    }

    // MARK: - 操作

    private mutating func play() {
        guard case .paused(let episode, let position, let duration, let speed) = state else { return }
        command(.setRate(speed))
        commit(.playing(episode: episode, position: position, duration: duration, speed: speed))
        if let failure = pending.failed {
            pending = PendingEngineOutcome.none
            enterErrored(engineDescription: failure)
        } else if pending.ended {
            pending = PendingEngineOutcome.none
            enterEnded()
        }
    }

    private mutating func pauseIfRunning() {
        switch state {
        case .loading(let episode, let resumePosition, let speed):
            command(.pause)
            commit(.paused(episode: episode, position: resumePosition,
                           duration: Double(episode.content.durationSeconds), speed: speed))
        case .playing(let episode, let position, let duration, let speed),
             .buffering(let episode, let position, let duration, let speed):
            command(.pause)
            commit(.paused(episode: episode, position: position, duration: duration, speed: speed))
        case .idle, .paused, .ended, .errored:
            break
        }
    }

    private mutating func seek(to seconds: Double) {
        switch state {
        case .loading(let episode, _, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: Double(episode.content.durationSeconds))
            command(.seek(target))
            commit(.loading(episode: episode, resumePosition: target, speed: speed))
        case .playing(let episode, _, let duration, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: duration)
            command(.seek(target))
            commit(.playing(episode: episode, position: target, duration: duration, speed: speed))
        case .buffering(let episode, _, let duration, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: duration)
            command(.seek(target))
            commit(.buffering(episode: episode, position: target, duration: duration, speed: speed))
        case .paused(let episode, _, let duration, let speed):
            let target = PlaybackRules.clampPosition(seconds, duration: duration)
            command(.seek(target))
            commit(.paused(episode: episode, position: target, duration: duration, speed: speed))
        case .idle, .ended, .errored:
            break
        }
    }

    private mutating func setSpeed(_ speed: Float) {
        guard PlaybackConstants.speeds.contains(speed) else { return }
        switch state {
        case .loading(let episode, let resumePosition, _):
            command(.setRate(speed))
            commit(.loading(episode: episode, resumePosition: resumePosition, speed: speed))
        case .playing(let episode, let position, let duration, _):
            command(.setRate(speed))
            commit(.playing(episode: episode, position: position, duration: duration, speed: speed))
        case .buffering(let episode, let position, let duration, _):
            command(.setRate(speed))
            commit(.buffering(episode: episode, position: position, duration: duration, speed: speed))
        case .paused(let episode, let position, let duration, _):
            commit(.paused(episode: episode, position: position, duration: duration, speed: speed))
        case .idle, .ended, .errored:
            break
        }
    }

    // MARK: - engine の事象

    /// `ready` と同じ進め方（`loading` → `paused` → `playing`）。`loading` でなければ何もしない。
    private mutating func advanceFromLoading() {
        guard case .loading(let episode, let resumePosition, let speed) = state else { return }
        let duration = Double(episode.content.durationSeconds)
        commit(.paused(episode: episode, position: resumePosition, duration: duration, speed: speed))
        commit(.playing(episode: episode, position: resumePosition, duration: duration, speed: speed))
    }

    private mutating func enterErrored(engineDescription: String?) {
        let episodeId = state.episodeId ?? ""
        let position = state.position
        command(.unload)
        commit(.errored(episodeId: episodeId, position: position, reason: .engineFailed(description: engineDescription)))
    }

    private mutating func enterEnded() {
        guard case .playing(let episode, _, let duration, _) = state else { return }
        command(.unload)
        commit(.ended(episode: episode, duration: duration))
        notify(.ended(episodeId: episode.content.id))
    }

    private mutating func engineEnded() {
        switch state {
        case .loading:
            advanceFromLoading()
            enterEnded()
        case .playing:
            enterEnded()
        case .buffering(let episode, let position, let duration, let speed):
            commit(.playing(episode: episode, position: position, duration: duration, speed: speed))
            enterEnded()
        case .paused:
            pending = PendingEngineOutcome(failed: pending.failed, ended: true)
        case .idle, .ended, .errored:
            break
        }
    }

    private mutating func engineFailed(_ description: String?) {
        switch state {
        case .loading, .playing, .buffering:
            enterErrored(engineDescription: description)
        case .paused:
            pending = PendingEngineOutcome(failed: .some(description), ended: pending.ended)
        case .idle, .ended, .errored:
            break
        }
    }

    private mutating func timeUpdate(seconds: Double, reportedDuration: Double) {
        let newState: PlaybackState
        switch state {
        case .playing(let episode, _, let duration, let speed):
            newState = .playing(episode: episode, position: seconds,
                                duration: reportedDuration > 0 ? reportedDuration : duration, speed: speed)
        case .buffering(let episode, _, let duration, let speed):
            newState = .buffering(episode: episode, position: seconds,
                                  duration: reportedDuration > 0 ? reportedDuration : duration, speed: speed)
        case .paused(let episode, _, let duration, let speed):
            newState = .paused(episode: episode, position: seconds,
                               duration: reportedDuration > 0 ? reportedDuration : duration, speed: speed)
        case .idle, .loading, .ended, .errored:
            return
        }
        state = newState
        effects.append(.updateState(newState))
        notify(.positionChanged(seconds: seconds, duration: newState.duration))
    }

    private mutating func interrupted() {
        switch state {
        case .loading, .playing, .buffering:
            pauseIfRunning()
            notify(.interruption(.began(wasPlaying: true)))
        case .paused:
            notify(.interruption(.began(wasPlaying: false)))
        case .idle, .ended, .errored:
            break
        }
    }
}
