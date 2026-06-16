//
//  PodcastViewModel.swift
//  NewsListenApp
//
//  Podcast タブの状態とロジック。一覧取得と AVPlayer による音声再生
//  （再生/一時停止・シーク・速度変更）を担う。
//

import Foundation
import Combine
import AVFoundation

/// Podcast タブの状態とロジックを担う ViewModel。
///
/// 一覧取得と、`AVPlayer` による音声再生（再生/一時停止・シーク・速度変更）を行う。
///
/// - Note: `AVPlayer` の操作と `@Published` 更新を同一コンテキストで行うため `@MainActor`。
///   `addPeriodicTimeObserver` 等の API 都合で `NSObject` を継承する。
@MainActor
final class PodcastViewModel: NSObject, ObservableObject {
    /// 表示中の Podcast 一覧。
    @Published var podcasts: [Podcast] = []
    /// 読み込み中かどうか。
    @Published var isLoading = false
    /// 直近のエラーメッセージ（なければ `nil`）。アラート表示に使う。
    @Published var errorMessage: String?
    /// 現在再生対象の Podcast（未再生なら `nil`）。
    @Published var currentPodcast: Podcast?
    /// 再生中かどうか。
    @Published var isPlaying = false
    /// 現在の再生位置（秒）。
    @Published var currentTime: Double = 0
    /// 現在の音声の総再生時間（秒）。
    @Published var duration: Double = 0
    /// 現在の再生速度（倍率）。
    @Published var playbackSpeed: Float = 1.0

    /// API 通信に使うクライアント。
    private let apiClient: APIClient
    /// 音声再生に使う `AVPlayer`（未再生時は `nil`）。
    private var player: AVPlayer?
    /// 再生位置を定期更新するためのタイムオブザーバ。解放時に取り外す。
    private var timeObserver: Any?

    /// ViewModel を生成する。
    /// - Parameter apiClient: API 通信に使うクライアント。
    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Data

    /// Podcast 一覧を取得して `podcasts` を更新する。失敗時は `errorMessage` に反映する。
    func loadPodcasts() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchPodcasts()
            podcasts = response.podcasts
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Playback

    /// 指定 Podcast の音声を先頭から再生する。再生中の音声があれば停止してから差し替える。
    /// - Parameter podcast: 再生対象の Podcast。`audioUrl` が不正な場合は何もしない。
    func play(podcast: Podcast) {
        guard let url = URL(string: podcast.audioUrl) else { return }

        // マナーモード（消音スイッチ ON）でも再生されるよう .playback を指定する。
        // 既定の .soloAmbient だと無音になり「再生されない」不具合になるため。
        configureAudioSession()

        stopPlayback()
        currentPodcast = podcast

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.rate = playbackSpeed

        // 再生位置の定期更新（0.5秒ごと）
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
            let itemDuration = playerItem.duration.seconds
            self?.duration = itemDuration.isNaN ? 0 : itemDuration
        }

        player?.play()
        isPlaying = true
    }

    /// 再生中なら一時停止し、停止中なら再生を再開する。
    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            // pause 後の再開でも設定済みの速度を保つため rate で再生する。
            player.rate = playbackSpeed
        }
        isPlaying.toggle()
    }

    /// 指定位置へシークする。
    /// - Parameter seconds: 移動先の再生位置（秒）。
    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    /// 再生速度を設定する。再生中なら即座に反映する。
    /// - Parameter speed: 再生速度（倍率）。
    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying { player?.rate = speed }
    }

    /// 再生を停止し、`AVPlayer`・タイムオブザーバ・再生状態を解放/リセットする。
    func stopPlayback() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// 音声セッションを `.playback` / `.spokenAudio` に設定する。
    ///
    /// マナーモード（消音スイッチ ON）でも再生されるようにするため。失敗しても再生は継続する。
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // セッション設定の失敗は致命的ではない（音量が小さくなる程度）ため、
            // 再生自体は継続させ、エラーのみ記録する。
            errorMessage = error.localizedDescription
        }
    }
}
