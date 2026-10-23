//
//  PlaybackRules.swift
//  NewsListenApp
//
//  再生の純関数（domain）。共有仕様 §6.1・§6.4。
//

import Foundation

enum PlaybackSource: Equatable {
    case cached
    case network
    case unavailable
}

enum PlaybackRules {
    static func resolvePlaybackSource(hasCached: Bool, isOnline: Bool) -> PlaybackSource {
        if hasCached { return .cached }
        return isOnline ? .network : .unavailable
    }

    static func resolveResumePosition(serverSeconds: Double, durationSeconds: Double) -> Double {
        if serverSeconds <= 0 { return 0 }
        if durationSeconds > 0 && serverSeconds >= durationSeconds - 2 { return 0 }
        return serverSeconds
    }

    /// 総時間が不明（0）の間は下限 0 だけで丸める。
    static func clampPosition(_ seconds: Double, duration: Double) -> Double {
        let lowerBounded = max(0, seconds)
        return duration > 0 ? min(duration, lowerBounded) : lowerBounded
    }

    static func isLoaded(_ state: PlaybackState) -> Bool {
        switch state {
        case .loading, .playing, .buffering, .paused:
            return true
        case .idle, .ended, .errored:
            return false
        }
    }
}
