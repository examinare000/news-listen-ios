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
    /// - title と subtitle は加工せず、曲名とアーティスト名に載せる。
    /// - duration は有限かつ正のときのみ載せる（未確定の NaN/∞ はロック画面表示を崩すため除外）。
    /// - elapsed は 0 未満を 0 に丸める。
    /// - rate は一時停止中に 0 を載せ、ロック画面側の進行表示を止める。
    /// - Parameter snapshot: ロック画面へ渡す再生情報。
    static func make(snapshot: NowPlayingSnapshot) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = snapshot.title
        info[MPMediaItemPropertyArtist] = snapshot.subtitle
        if snapshot.duration.isFinite, snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, snapshot.elapsed)
        // 一時停止中は rate=0 を載せてロック画面の進行を止める。
        info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.isPlaying ? Double(snapshot.rate) : 0.0
        return info
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
