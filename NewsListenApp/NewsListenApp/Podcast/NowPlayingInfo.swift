//
//  NowPlayingInfo.swift
//  NewsListenApp
//
//  バックグラウンド再生（issue #79）の中核ロジックを、AVPlayer や
//  MPNowPlayingInfoCenter の副作用から切り離した純粋関数として提供する。
//  これにより、ロック画面/コントロールセンターに載せる情報と、割り込み/ルート変更時の
//  挙動を実機なしで単体テストできる。
//

import Foundation
import AVFoundation
import MediaPlayer

/// `MPNowPlayingInfoCenter` に渡す Now Playing 情報辞書を組み立てる純粋ヘルパ。
enum NowPlayingInfo {
    /// 再生状態から Now Playing 情報辞書を組み立てる。
    ///
    /// - duration は有限かつ正のときのみ載せる（未確定の NaN/∞ はロック画面表示を崩すため除外）。
    /// - elapsed は 0 未満を 0 に丸める。
    /// - rate は一時停止中に 0 を載せ、ロック画面側の進行表示を止める。
    /// - Parameters:
    ///   - podcast: 再生中の Podcast。
    ///   - elapsed: 現在の再生位置（秒）。
    ///   - duration: 総再生時間（秒）。
    ///   - rate: 再生速度（倍率）。
    ///   - isPlaying: 再生中かどうか。
    static func make(
        podcast: Podcast,
        elapsed: Double,
        duration: Double,
        rate: Float,
        isPlaying: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title(for: podcast)
        info[MPMediaItemPropertyArtist] = DifficultyLabel.text(for: podcast.difficulty)
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        // 一時停止中は rate=0 を載せてロック画面の進行を止める。
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0.0
        return info
    }

    /// ロック画面に表示するタイトルを決める。日本語イントロがあれば使い、無ければ汎用名。
    /// - Parameter podcast: 対象の Podcast。
    static func title(for podcast: Podcast) -> String {
        let intro = podcast.japaneseIntroText.trimmingCharacters(in: .whitespacesAndNewlines)
        return intro.isEmpty ? "ニュースポッドキャスト" : intro
    }
}

/// 音声割り込み・ルート変更に対する一時停止/再開ポリシーの純粋判定。
enum InterruptionPolicy {
    /// 割り込み終了時に再生を再開すべきか。`shouldResume` オプションの有無で判定する。
    /// - Parameter options: 割り込み終了通知に含まれるオプション。
    static func shouldResume(options: AVAudioSession.InterruptionOptions) -> Bool {
        options.contains(.shouldResume)
    }

    /// ルート変更時に一時停止すべきか。イヤホン抜去等（旧デバイス喪失）で true。
    /// - Parameter reason: ルート変更の理由。
    static func shouldPause(forRouteChangeReason reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .oldDeviceUnavailable
    }
}
