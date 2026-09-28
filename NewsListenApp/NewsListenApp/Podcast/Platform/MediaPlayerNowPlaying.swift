//
//  MediaPlayerNowPlaying.swift
//  NewsListenApp
//
//  `NowPlayingCenter` の本番実装。`MPNowPlayingInfoCenter` をクリアするだけの薄い adapter。
//

import MediaPlayer

/// `MPNowPlayingInfoCenter` を使う本番実装（I-S2 では `clear()` のみ）。
final class MediaPlayerNowPlaying: NowPlayingCenter {
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
