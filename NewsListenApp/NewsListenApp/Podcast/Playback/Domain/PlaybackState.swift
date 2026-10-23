//
//  PlaybackState.swift
//  NewsListenApp
//
//  再生状態の union と派生値（domain）。遷移の決定は `PlaybackSession`（application）が持つ。
//

import Foundation

enum PlaybackErrorReason: Equatable {
    case offlineUncached
    case invalidSource
    case engineFailed(description: String?)
    case fetchFailed(ApiFailure)
}

enum PlaybackState: Equatable {
    case idle
    case loading(episode: PlayableEpisode, resumePosition: Double, speed: Float)
    case playing(episode: PlayableEpisode, position: Double, duration: Double, speed: Float)
    case buffering(episode: PlayableEpisode, position: Double, duration: Double, speed: Float)
    case paused(episode: PlayableEpisode, position: Double, duration: Double, speed: Float)
    case ended(episode: PlayableEpisode, duration: Double)
    case errored(episodeId: String, position: Double, reason: PlaybackErrorReason)
}

extension PlaybackState {
    var episodeId: String? {
        switch self {
        case .idle:
            return nil
        case .loading(let episode, _, _),
             .playing(let episode, _, _, _),
             .buffering(let episode, _, _, _),
             .paused(let episode, _, _, _),
             .ended(let episode, _):
            return episode.content.id
        case .errored(let episodeId, _, _):
            return episodeId
        }
    }

    var position: Double {
        switch self {
        case .idle:
            return 0
        case .loading(_, let resumePosition, _):
            return resumePosition
        case .playing(_, let position, _, _),
             .buffering(_, let position, _, _),
             .paused(_, let position, _, _),
             .errored(_, let position, _):
            return position
        case .ended(_, let duration):
            return duration
        }
    }

    var duration: Double {
        switch self {
        case .idle, .errored:
            return 0
        case .loading(let episode, _, _):
            return Double(episode.content.durationSeconds)
        case .playing(_, _, let duration, _),
             .buffering(_, _, let duration, _),
             .paused(_, _, let duration, _),
             .ended(_, let duration):
            return duration
        }
    }

    var speed: Float? {
        switch self {
        case .loading(_, _, let speed),
             .playing(_, _, _, let speed),
             .buffering(_, _, _, let speed),
             .paused(_, _, _, let speed):
            return speed
        case .idle, .ended, .errored:
            return nil
        }
    }

    var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}

enum InterruptionPhase: Equatable {
    case began(wasPlaying: Bool)
    case ended(shouldResume: Bool)
}
