//
//  PlaybackConstants.swift
//  NewsListenApp
//
//  再生速度・スキップ秒の単一の真実。プレイヤー UI（AudioPlayerView）と
//  ロック画面/コントロールセンター（PodcastViewModel の MPRemoteCommandCenter）で
//  同じ値を使い、片方だけ変更して食い違う回帰を防ぐ。
//

import Foundation

/// 再生操作の共有定数。
enum PlaybackConstants {
    /// 速度選択肢（倍率）。UI の Picker とリモートコマンドの supportedPlaybackRates で共有する。
    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5]
    /// 戻るスキップ秒。
    static let skipBackwardSeconds: Double = 15
    /// 進むスキップ秒。
    static let skipForwardSeconds: Double = 30
}
