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
import MediaPlayer
import SwiftUI

/// 音声再生の準備状態を表す列挙型。
enum DownloadState: Equatable {
    /// ダウンロードされていない。
    case notDownloaded
    /// 現在ダウンロード中。
    case downloading
    /// ダウンロード済み。
    case downloaded
}

/// Podcast タブの状態とロジックを担う ViewModel。
///
/// 一覧取得と、`AVPlayer` による音声再生（再生/一時停止・シーク・速度変更）を行う。
/// オフライン再生のため、キャッシュマネージャとネットワーク監視を注入可能。
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
    /// ダウンロード済み Podcast ID の集合（ViewModel のみが更新する）。
    @Published private(set) var downloadedIds: Set<String> = []
    /// ダウンロード中 Podcast ID の集合（ViewModel のみが更新する）。
    @Published private(set) var downloadingIds: Set<String> = []

    /// API 通信に使うクライアント。
    private let apiClient: APIClient
    /// 音声キャッシュを管理するマネージャ。
    private let cacheManager: AudioCacheManager
    /// ネットワーク接続状態を監視する。
    private let networkMonitor: NetworkMonitoring
    /// 音声再生に使う `AVPlayer`（未再生時は `nil`）。
    private var player: AVPlayer?
    /// 再生位置を定期更新するためのタイムオブザーバ。解放時に取り外す。
    private var timeObserver: Any?
    /// 再生位置をサーバーへ定期同期するタイマー。
    private var syncTimer: Timer?
    /// リモートコマンド・音声通知の購読を設定済みか（多重登録防止）。
    private var backgroundPlaybackConfigured = false
    /// 割り込み（電話等）発生前に再生中だったか。割り込み終了時の再開判定に使う。
    private var wasPlayingBeforeInterruption = false
    /// 登録した MPRemoteCommand とその解除トークン。deinit で確実に解除する。
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    /// 登録した音声通知オブザーバ。deinit で確実に解除する。
    private var audioNotificationObservers: [NSObjectProtocol] = []

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - apiClient: API 通信に使うクライアント。
    ///   - cacheManager: 音声キャッシュマネージャ（既定: `AudioCacheManager()`）。
    ///   - networkMonitor: ネットワーク監視（既定: 実機監視の `NetworkMonitor()`）。
    init(
        apiClient: APIClient,
        cacheManager: AudioCacheManager = AudioCacheManager(),
        networkMonitor: NetworkMonitoring = NetworkMonitor()
    ) {
        self.apiClient = apiClient
        self.cacheManager = cacheManager
        self.networkMonitor = networkMonitor
    }

    // MARK: - Data

    /// Podcast 一覧を取得して `podcasts` を更新する。失敗時は `errorMessage` に反映する。
    /// ロード後、既存キャッシュから downloadedIds を同期する。
    func loadPodcasts() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchPodcasts()
            podcasts = response.podcasts
            syncDownloadedState()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// ローカルキャッシュから、ダウンロード済み ID を同期する。
    func syncDownloadedState() {
        downloadedIds = Set(podcasts.filter { cacheManager.isCached($0.id) }.map { $0.id })
    }

    /// 指定 Podcast の再生準備状態を返す。
    /// - Parameter podcastId: Podcast ID。
    func downloadState(for podcastId: String) -> DownloadState {
        Self.downloadState(forId: podcastId, downloaded: downloadedIds, downloading: downloadingIds)
    }

    /// ダウンロード状態を導出する純粋関数（副作用なし・テスト容易）。downloading を downloaded より優先。
    static func downloadState(
        forId podcastId: String,
        downloaded: Set<String>,
        downloading: Set<String>
    ) -> DownloadState {
        if downloading.contains(podcastId) {
            return .downloading
        } else if downloaded.contains(podcastId) {
            return .downloaded
        } else {
            return .notDownloaded
        }
    }

    /// 指定 Podcast の音声をダウンロード・キャッシュし、downloadedIds に追加する。
    /// ダウンロード中の重複を防ぐため、已に downloading/downloaded 中なら何もしない。
    /// - Parameter podcast: ダウンロード対象の Podcast。
    func download(podcast: Podcast) async {
        guard !downloadingIds.contains(podcast.id), !downloadedIds.contains(podcast.id) else { return }

        downloadingIds.insert(podcast.id)
        defer { downloadingIds.remove(podcast.id) }

        do {
            // 署名付き URL を新たに取得（再生時点での最新 URL を確保）。
            let fresh = try await apiClient.fetchPodcast(id: podcast.id)
            guard let audioURLString = URL(string: fresh.audioUrl) else {
                errorMessage = "Invalid audio URL"
                return
            }
            // 音声データをダウンロード。
            let audioData = try await apiClient.downloadAudio(from: audioURLString)
            // キャッシュに保存。
            try cacheManager.cache(audioData, for: podcast.id)
            // 成功時のみ downloadedIds に追加。
            downloadedIds.insert(podcast.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// キャッシュからダウンロード済み Podcast を削除する。
    /// - Parameter podcast: 削除対象の Podcast。
    func removeDownload(podcast: Podcast) async {
        do {
            try cacheManager.remove(podcast.id)
            downloadedIds.remove(podcast.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playback

    /// 指定 Podcast の再生 URL を解決する。
    ///
    /// - キャッシュ有：ローカルファイル URL を返す。
    /// - キャッシュ無+オンライン：podcast.audioUrl を URL(string:) で解析して返す。
    /// - キャッシュ無+オフライン：nil を返す。
    ///
    /// - Parameters:
    ///   - podcast: 対象の Podcast。
    ///   - isOnline: ネットワーク接続状態。
    /// - Returns: 再生可能な URL、または nil（再生不可）。
    static func resolvePlaybackURL(for podcast: Podcast, isOnline: Bool, cacheManager: AudioCacheManager) -> URL? {
        // キャッシュ有なら優先的に返す。
        if cacheManager.isCached(podcast.id) {
            return cacheManager.cachedURL(for: podcast.id)
        }
        // キャッシュ無+オンライン：署名付き URL を使う。
        if isOnline {
            return URL(string: podcast.audioUrl)
        }
        // キャッシュ無+オフライン：再生不可。
        return nil
    }

    /// 指定 Podcast の音声を先頭から再生する。再生中の音声があれば停止してから差し替える。
    ///
    /// オフライン+未キャッシュの場合は、errorMessage をセットして何もしない。
    /// オンライン+未キャッシュの場合は、署名付き URL を再取得して再生（失敗時は元 audioUrl でフォールバック）。
    ///
    /// - Parameter podcast: 再生対象の Podcast。
    func play(podcast: Podcast) async {
        // 再生 URL を解決する。
        guard let url = Self.resolvePlaybackURL(for: podcast, isOnline: networkMonitor.isOnline, cacheManager: cacheManager) else {
            errorMessage = "Offline and not cached"
            return
        }

        // マナーモード（消音スイッチ ON）でも再生されるよう .playback を指定する。
        // 既定の .soloAmbient だと無音になり「再生されない」不具合になるため。
        configureAudioSession()
        // ロック画面/コントロールセンター操作と割り込み対応を一度だけ設定する。
        configureBackgroundPlayback()

        stopPlayback()
        currentPodcast = podcast

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.rate = playbackSpeed

        // 前回の再生位置から復元する。同期 seek ヘルパに委譲し、async コンテキストでの
        // AVPlayer.seek(to:) async オーバーロード選択（要 await）を避ける。
        if podcast.playbackPositionSeconds > 0 {
            seek(to: podcast.playbackPositionSeconds)
        }

        // 再生位置の定期更新（0.5秒ごと）
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // queue: .main 指定によりこのクロージャは常にメインスレッドで呼ばれるため、
            // MainActor 隔離を明示して @Published / Now Playing 更新を安全に行う。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                let itemDuration = playerItem.duration.seconds
                self.duration = itemDuration.isNaN ? 0 : itemDuration
                // ロック画面の経過/総時間のみ軽量更新する（辞書全構築は離散イベント時のみ）。
                self.updateNowPlayingElapsed()
            }
        }

        player?.play()
        isPlaying = true
        updateNowPlayingInfo()

        // 再生位置をサーバーへ定期同期（15秒ごと）。
        startPlaybackPositionSync()
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
        updateNowPlayingInfo()
    }

    /// 指定位置へシークする。
    /// - Parameter seconds: 移動先の再生位置（秒）。
    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingInfo()
    }

    /// 再生速度を設定する。再生中なら即座に反映する。
    /// - Parameter speed: 再生速度（倍率）。
    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying { player?.rate = speed }
        updateNowPlayingInfo()
    }

    /// 再生を停止し、`AVPlayer`・タイムオブザーバ・再生状態を解放/リセットする。
    /// 同期完了を試みてからシャットダウンする。
    func stopPlayback() {
        // 再生位置を最後に同期しておく。
        syncPlaybackPositionIfNeeded()

        // タイマーを停止。
        syncTimer?.invalidate()
        syncTimer = nil

        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0

        // ロック画面/コントロールセンターの再生情報を消す。
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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

    // MARK: - Background Playback (Now Playing / Remote Command / 割り込み)

    /// ロック画面/コントロールセンター操作と割り込み対応を一度だけ設定する。
    /// 再生のたびに呼ばれるが、多重登録を避けるためフラグで初回のみ実行する。
    private func configureBackgroundPlayback() {
        guard !backgroundPlaybackConfigured else { return }
        backgroundPlaybackConfigured = true
        configureRemoteCommands()
        registerAudioNotifications()
    }

    /// `MPRemoteCommandCenter` の各コマンドを ViewModel の操作へ配線する。
    ///
    /// `addTarget(self, action:)` はシングルトンの command center が `self` を強参照し、
    /// `deinit` が発火せずリーク・ターゲット累積を招くため、`[weak self]` クロージャ方式で登録し、
    /// 解除トークンを保持して `deinit` で確実に外す。コマンドはメインスレッドで配信されるため
    /// `MainActor.assumeIsolated` で `@MainActor` 隔離を明示する。
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        func register(
            _ command: MPRemoteCommand,
            _ body: @escaping (PodcastViewModel, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
        ) {
            let target = command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return .commandFailed }
                    return body(self, event)
                }
            }
            remoteCommandTargets.append((command, target))
        }

        register(center.playCommand) { vm, _ in
            guard vm.player != nil else { return .noSuchContent }
            if !vm.isPlaying { vm.togglePlayPause() }
            return .success
        }
        register(center.pauseCommand) { vm, _ in
            guard vm.player != nil else { return .noSuchContent }
            if vm.isPlaying { vm.togglePlayPause() }
            return .success
        }
        register(center.togglePlayPauseCommand) { vm, _ in
            guard vm.player != nil else { return .noSuchContent }
            vm.togglePlayPause()
            return .success
        }

        // スキップ秒は AudioPlayerView と共有定数で揃える。
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlaybackConstants.skipBackwardSeconds)]
        register(center.skipBackwardCommand) { vm, _ in
            guard vm.player != nil else { return .noSuchContent }
            vm.seek(to: max(0, vm.currentTime - PlaybackConstants.skipBackwardSeconds))
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlaybackConstants.skipForwardSeconds)]
        register(center.skipForwardCommand) { vm, _ in
            guard vm.player != nil else { return .noSuchContent }
            vm.seek(to: min(vm.duration, vm.currentTime + PlaybackConstants.skipForwardSeconds))
            return .success
        }

        register(center.changePlaybackPositionCommand) { vm, event in
            guard vm.player != nil,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            vm.seek(to: positionEvent.positionTime)
            return .success
        }

        center.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackConstants.speeds.map { NSNumber(value: $0) }
        register(center.changePlaybackRateCommand) { vm, event in
            // 他のコマンドと整合させ、未再生時は no-op で .noSuchContent を返す。
            guard vm.player != nil,
                  let rateEvent = event as? MPChangePlaybackRateCommandEvent else { return .noSuchContent }
            vm.setSpeed(rateEvent.playbackRate)
            return .success
        }
    }

    /// 割り込み・ルート変更の通知購読を登録する。
    ///
    /// `AVAudioSession` の通知はメインスレッド配信が保証されないため、`queue: .main` を指定して
    /// 必ずメインで受け、`@MainActor`/`@Published` 状態を安全に更新する。解除トークンを保持し deinit で外す。
    private func registerAudioNotifications() {
        let nc = NotificationCenter.default
        let interruption = nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        let route = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
        audioNotificationObservers.append(contentsOf: [interruption, route])
    }

    /// 現在の再生状態を `MPNowPlayingInfoCenter` に反映する。再生対象が無ければ消す。
    /// タイトル・難易度などを含む辞書を全構築するため、再生/一時停止・シーク・速度変更などの
    /// 離散イベント時に呼ぶ（高頻度の経過更新は ``updateNowPlayingElapsed()`` を使う）。
    private func updateNowPlayingInfo() {
        guard let podcast = currentPodcast else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = NowPlayingInfo.make(
            podcast: podcast,
            elapsed: currentTime,
            duration: duration,
            rate: playbackSpeed,
            isPlaying: isPlaying
        )
    }

    /// 経過/総時間のみを既存の Now Playing 辞書に上書きする軽量更新。
    /// 0.5 秒ごとの periodic observer から呼び、辞書全構築のコストを避ける。
    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTime)
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Interruption / Route Change Handlers

    /// 電話などの割り込みに応じて一時停止/再開する。割り込み前に再生中だった場合のみ再開する。
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { togglePlayPause() }
        case .ended:
            let options: AVAudioSession.InterruptionOptions
            if let raw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: raw)
            } else {
                options = []
            }
            if InterruptionPolicy.shouldResume(options: options), wasPlayingBeforeInterruption, !isPlaying {
                // セッションを再有効化してから再開する。
                try? AVAudioSession.sharedInstance().setActive(true)
                togglePlayPause()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    /// イヤホン抜去などルート変更に応じて一時停止する（旧デバイス喪失時）。
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if InterruptionPolicy.shouldPause(forRouteChangeReason: reason), isPlaying {
            togglePlayPause()
        }
    }

    deinit {
        // 音声通知オブザーバとリモートコマンドのターゲットを解除する。
        // いずれも [weak self] クロージャ方式のため self を強参照せず deinit は確実に発火し、
        // シングルトン（NotificationCenter / MPRemoteCommandCenter）への残存を防ぐ。
        // これらの解除 API はスレッド安全で actor 分離に依存しない。
        for observer in audioNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
    }

    // MARK: - Playback Position Sync

    /// 再生位置をサーバーへ定期同期するタイマーを開始する。
    /// 再生位置を 15 秒ごとにサーバーへ同期する。
    private func startPlaybackPositionSync() {
        // 既に起動していれば何もしない。
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.syncPlaybackPositionIfNeeded()
        }
    }

    /// 現在の再生位置をサーバーへ同期する。
    /// currentPodcast が nil の場合や通信失敗時はサイレント失敗。
    private func syncPlaybackPositionIfNeeded() {
        guard let podcast = currentPodcast else { return }
        Task {
            do {
                _ = try await apiClient.updatePlaybackPosition(podcastId: podcast.id, positionSeconds: currentTime)
            } catch {
                // 同期失敗時はログしない（ネットワーク一時的な失敗等を避けるため）。
            }
        }
    }
}
