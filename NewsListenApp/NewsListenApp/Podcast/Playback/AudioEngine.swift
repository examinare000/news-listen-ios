//
//  AudioEngine.swift
//  NewsListenApp
//
//  音声再生エンジンの port。`PodcastViewModel` はこの protocol だけを参照し、
//  AVFoundation / MediaPlayer を import しない（leakage 検査: GrepOracleTests）。
//

import Foundation

/// 音声再生エンジンを隠す port。
///
/// 事象は load ごとに新しい stream で届く。利用側は `load` の直後に同期的に `events` を取り出して保持し、
/// 後から（別の Task の中などで）読み直さない。
@MainActor
protocol AudioEngine: AnyObject {
    /// 読み込む。すでに読み込み済みなら、先に `stop` と同じ後始末をする。load ごとに新しい事象 stream を作る。
    /// - Returns: 致命的でない準備失敗の説明（無ければ `nil`）。
    func load(url: URL) -> String?
    /// 再生を始める。読み込み済みでなければ何もしない。
    func play()
    /// 一時停止する。読み込み済みでなければ何もしない。
    func pause()
    /// 指定位置（秒）へ移動する。読み込み済みでなければ何もしない。
    func seek(to seconds: Double)
    /// 再生速度を設定する（0 以外なら再生が進む）。読み込み済みでなければ何もしない。
    func setRate(_ rate: Float)
    /// 止めて読み込みを外し、現在の stream を finish する。冪等。以後も `load` で再利用できる。
    func stop()
    /// 現在の load の stream。読み込み済みでなければ、すぐ終わる stream。
    var events: AsyncStream<EngineEvent> { get }
}

/// 再生エンジンが VM へ伝える事象。
enum EngineEvent: Equatable {
    case ready
    case buffering
    case resumed
    case paused
    case ended
    case failed(description: String?)
    case timeUpdate(seconds: Double, duration: Double)
    case interrupted
    case interruptionEnded(shouldResume: Bool)
    case outputDeviceLost
}
