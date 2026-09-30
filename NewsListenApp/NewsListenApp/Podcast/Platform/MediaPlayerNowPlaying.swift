//
//  MediaPlayerNowPlaying.swift
//  NewsListenApp
//
//  `NowPlayingCenter` の本番実装。`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` を使う adapter。
//

import MediaPlayer

/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` を使う本番実装。登録表は持たない（解除は token が担う）。
final class MediaPlayerNowPlaying: NowPlayingCenter {
    func update(_ info: [String: Any]) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 経過/総時間のみを既存の Now Playing 辞書に上書きする軽量更新。
    /// 0.5 秒ごとの定期更新から呼び、辞書全構築のコストを避ける。
    func updateElapsed(_ elapsed: Double, duration: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// `MPRemoteCommandCenter` の各コマンドを handler へ配線する。
    ///
    /// `addTarget(self, action:)` はシングルトンの command center が `self` を強参照し、解除漏れで
    /// ターゲットが累積するため、クロージャ方式で登録し、解除トークンを token に閉じ込める。
    /// コマンドはメインスレッドで配信されるため `MainActor.assumeIsolated` で隔離を明示する。
    func registerCommands(
        _ handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult
    ) -> RemoteCommandRegistration {
        let center = MPRemoteCommandCenter.shared()
        var targets: [(MPRemoteCommand, Any)] = []

        func register(_ command: MPRemoteCommand, _ body: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            let target = command.addTarget { event in
                MainActor.assumeIsolated { body(event) }
            }
            targets.append((command, target))
        }

        register(center.playCommand) { _ in Self.status(of: handler(.play)) }
        register(center.pauseCommand) { _ in Self.status(of: handler(.pause)) }
        register(center.togglePlayPauseCommand) { _ in Self.status(of: handler(.togglePlayPause)) }

        // スキップ秒は AudioPlayerView と共有定数で揃える。
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlaybackConstants.skipBackwardSeconds)]
        register(center.skipBackwardCommand) { _ in Self.status(of: handler(.skipBackward)) }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlaybackConstants.skipForwardSeconds)]
        register(center.skipForwardCommand) { _ in Self.status(of: handler(.skipForward)) }

        register(center.changePlaybackPositionCommand) { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return Self.status(of: handler(.changePosition(positionEvent.positionTime)))
        }

        center.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackConstants.speeds.map { NSNumber(value: $0) }
        register(center.changePlaybackRateCommand) { event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else { return .noSuchContent }
            return Self.status(of: handler(.changeRate(rateEvent.playbackRate)))
        }

        let registered = targets
        return RemoteCommandRegistration(removal: {
            for (command, target) in registered {
                command.removeTarget(target)
            }
        })
    }

    func unregister(_ registration: RemoteCommandRegistration) {
        registration.cancel()
    }

    private static func status(of result: RemoteCommandResult) -> MPRemoteCommandHandlerStatus {
        switch result {
        case .success: return .success
        case .noSuchContent: return .noSuchContent
        case .commandFailed: return .commandFailed
        }
    }
}
