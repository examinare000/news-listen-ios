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

// AVPlayer の操作と @Published 更新を同一コンテキストで行うため @MainActor。
// addPeriodicTimeObserver 等の API 都合で NSObject を継承する。
@MainActor
final class PodcastViewModel: NSObject, ObservableObject {
    @Published var podcasts: [Podcast] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPodcast: Podcast?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackSpeed: Float = 1.0

    private let apiClient: APIClient
    private var player: AVPlayer?
    private var timeObserver: Any?

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Data

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

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
    }

    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying { player?.rate = speed }
    }

    func stopPlayback() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

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
