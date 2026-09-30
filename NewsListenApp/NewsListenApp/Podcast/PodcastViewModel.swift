//
//  PodcastViewModel.swift
//  NewsListenApp
//
//  Podcast タブの状態とロジック。一覧取得と、`AudioEngine` port 越しの音声再生
//  （再生/一時停止・シーク・速度変更）を担う。
//

import Foundation
import Combine
import SwiftUI
import UIKit

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
/// 一覧取得と、`AudioEngine` port 越しの音声再生（再生/一時停止・シーク・速度変更）を行う。
/// オフライン再生のため、キャッシュマネージャとネットワーク監視を注入可能。
///
/// - Note: 再生エンジンの操作と `@Published` 更新を同一コンテキストで行うため `@MainActor`。
///   既存の構成を保つため `NSObject` を継承する。
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
    /// 再生バッファが不足し一時的に待機中かどうか（issue #51）。
    /// エンジンの事象 `buffering` / `resumed` / `paused` を反映する。
    @Published var isBuffering = false
    /// ダウンロード済み Podcast ID の集合（ViewModel のみが更新する）。
    @Published private(set) var downloadedIds: Set<String> = []
    /// ダウンロード中 Podcast ID の集合（ViewModel のみが更新する）。
    @Published private(set) var downloadingIds: Set<String> = []
    /// 再生キュー（連続再生・プレイリスト / issue #81）。
    @Published private(set) var queue = PlaybackQueue()
    /// 現在ネットワークがオンラインかどうか（オフラインバナー表示用に View から購読する・issue #54）。
    @Published private(set) var isOnline: Bool
    /// キュー終端まで聴き終えたかどうか（完了時プレイヤー自動収束用）。
    /// `currentPodcast` は語彙/クイズ導線のため聴き終えた後も保持するため、
    /// 「フルプレイヤー」と「聴き終わりましたのコンパクト表示」の切替はこのフラグで判定する。
    @Published private(set) var didFinishCurrentEpisode = false

    /// プレイヤー UI の表示形態（ミニ/フル/非表示）。
    /// 遷移規則は ``PlayerPresentation`` と ``play(podcast:expandsPlayer:)`` を参照。
    @Published private(set) var presentation: PlayerPresentation = .hidden

    /// 一覧画面の表示状態（ロード中/エラー/空/一覧）。
    /// ロード失敗と「本当に空」を同一の空状態に畳んで表示しないよう、View はこの値のみで分岐する（issue #53）。
    var displayState: ListDisplayState {
        ListDisplayState.resolve(isLoading: isLoading, isEmpty: podcasts.isEmpty, errorMessage: errorMessage)
    }

    /// エラーアラート（`.alert`）を表示すべきかどうか。
    /// 一覧が空でインラインエラー表示（`displayState == .error`）が出ている場合は、
    /// 同じエラーの二重表示を避けるためアラートを出さない（issue #58）。
    var shouldPresentErrorAlert: Bool {
        ListDisplayState.shouldPresentAlert(errorMessage: errorMessage, displayState: displayState)
    }

    /// API 通信に使うクライアント。
    private let apiClient: APIClient
    /// 音声キャッシュを管理するマネージャ。
    private let cacheManager: AudioCacheManager
    /// ネットワーク接続状態を監視する。
    private let networkMonitor: NetworkMonitoring
    /// 完聴送信後に共有ストリークを再取得する注入コールバック。
    private let refreshListeningStreak: @MainActor () async -> Void
    /// 音声再生エンジン（AVPlayer を隠す port）。
    private let engine: any AudioEngine
    /// ロック画面の再生情報とリモートコマンドを隠す port。
    private let nowPlaying: NowPlayingCenter
    /// エンジンに音声を読み込み済みか（`load` で真、`stop` で偽）。TP5: owner user／導入 I-S3a／
    /// 削除条件 I-S3b2 で Session の状態に置き換わった時。
    private var isAudioLoaded = false
    /// 現在の load の事象 stream を購読する Task。tearDown で cancel する。
    private var engineEventTask: Task<Void, Never>?
    /// 再生位置をサーバーへ定期同期するタイマー。
    private var syncTimer: Timer?
    /// リモートコマンドの登録 token（初回の再生で 1 回だけ登録する。多重登録防止を兼ねる）。deinit で解除する。
    private var remoteCommandRegistration: RemoteCommandRegistration?
    /// 割り込み（電話等）発生前に再生中だったか。割り込み終了時の再開判定に使う。
    private var wasPlayingBeforeInterruption = false

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - apiClient: API 通信に使うクライアント。
    ///   - cacheManager: 音声キャッシュマネージャ（既定: `AudioCacheManager()`）。
    ///   - networkMonitor: ネットワーク監視（既定: 実機監視の `NetworkMonitor()`）。
    ///   - engine: 再生エンジン（既定: `AVPlayerEngine()`。Preview とテスト用。App は共有の 1 個を渡す）。
    ///   - nowPlaying: ロック画面 port（既定: `MediaPlayerNowPlaying()`。Preview とテスト用）。
    init(
        apiClient: APIClient,
        cacheManager: AudioCacheManager = AudioCacheManager(),
        networkMonitor: NetworkMonitoring = NetworkMonitor(),
        refreshListeningStreak: @escaping @MainActor () async -> Void = {},
        engine: any AudioEngine = AVPlayerEngine(),
        nowPlaying: NowPlayingCenter = MediaPlayerNowPlaying()
    ) {
        self.apiClient = apiClient
        self.cacheManager = cacheManager
        self.networkMonitor = networkMonitor
        self.refreshListeningStreak = refreshListeningStreak
        self.engine = engine
        self.nowPlaying = nowPlaying
        self.isOnline = networkMonitor.isOnline
        // NSObject 継承のため、`$isOnline` 等 self を用いるプロパティラッパアクセスは
        // super.init() 完了後でなければならない。
        super.init()
        networkMonitor.isOnlinePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)
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
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .podcast)
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

    /// オフライン時、指定のダウンロード状態が再生可能かどうかを返す（一覧の視覚的区別に使用・issue #54）。
    /// ダウンロード済みのみ再生可能。純粋関数（副作用なし・テスト容易）。
    static func isPlayableWhileOffline(downloadState: DownloadState) -> Bool {
        downloadState == .downloaded
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
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .podcast)
        } catch {
            // ApiFailure を経由しないキャッシュ書込の失敗もここに届く（SG-S1-7 = (s1)。射程外）。
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
    /// - Parameters:
    ///   - podcast: 再生対象の Podcast。
    ///   - expandsPlayer: true（既定）ならフルプレイヤーを開く。キュー自動遷移や
    ///     「もう一度聴く」のような、利用者が明示的にエピソードを選んでいない・
    ///     既に表示形態を選んでいる経路では false を渡して現在の形態を保つ
    ///     （ミニ再生中の閲覧をシート表示で妨げない）。
    func play(podcast: Podcast, expandsPlayer: Bool = true) async {
        // 再生 URL を解決する。
        guard let url = Self.resolvePlaybackURL(for: podcast, isOnline: networkMonitor.isOnline, cacheManager: cacheManager) else {
            errorMessage = "Offline and not cached"
            return
        }
        // ガード通過＝再生開始が確定した経路なので、前回の失敗アラートが残留しないようここで消す（issue #58）。
        errorMessage = nil
        // 同様に、ガード通過後（＝実際に再生が始まる経路）でのみ収束表示を解除する。
        // オフライン+未キャッシュで失敗した replay はコンパクト状態のまま残す（guard 手前で return するため未到達）。
        didFinishCurrentEpisode = false

        // ロック画面/コントロールセンター操作と割り込み対応を一度だけ設定する。
        configureBackgroundPlayback()

        stopPlayback()
        currentPodcast = podcast
        if expandsPlayer {
            presentation = .expanded
        } else if presentation == .hidden {
            // 明示展開しない経路でも、再生が始まる以上ミニプレイヤーは出す（防御的既定）。
            presentation = .mini
        }

        // AudioSession の設定は engine.load の中で行い、失敗しても再生は継続する（致命的でない）。
        if let warning = engine.load(url: url) {
            errorMessage = warning
        }
        isAudioLoaded = true
        // WHY: load の直後に同期的に stream を取り出して Task へ渡す。購読 Task の本体で `engine.events` を
        //      読むと、play(a) → play(b) が続けて走ったとき cancel 済みの古い Task が新しい load の
        //      stream を購読してしまう。
        let stream = engine.events
        engine.setRate(playbackSpeed)

        // 前回の再生位置から復元する。
        //
        // 末尾付近の保存位置は「聴き終えた」記録なので復元せず先頭から再生する
        // （backend の markCompleted は completed_at のみ書き込み、position はリセットしないため、
        // 完聴済みエピソードの再タップが末尾へ即 seek → 即 didPlayToEndTime の完了ループになるのを防ぐ）。
        // durationSeconds > 0 の前置が必須: 0（メタデータ欠損）だと isAtEnd が常に true になり
        // レジューム機能が全面無効化される。
        // WHY: 固定2秒ウィンドウ（末尾 2 秒以内は復元しない）は、本番のニュース Podcast が
        //      分単位尺のみ生成される前提に基づいている。極短エピソード（数秒尺）では全域が
        //      末尾扱いになり得るが、本番制約により許容。
        let isAtEnd = podcast.durationSeconds > 0
            && podcast.playbackPositionSeconds >= Double(podcast.durationSeconds) - 2
        if podcast.playbackPositionSeconds > 0 && !isAtEnd {
            seek(to: podcast.playbackPositionSeconds)
        }

        // 終了した episode の ID を load 時に閉じ込めて渡す。事象の配送は非同期なので、発火時点で
        // `currentPodcast` を読むと、その間に利用者が別エピソードへ切り替えていた場合に新しい ID を
        // 誤って「終了した episode の ID」として渡してしまい、handlePlaybackEnded 側の stale ガード
        // （currentPodcast?.id != endedId）が役目を果たせなくなる（レビュー指摘 PR #74）。
        let endedId = podcast.id
        engineEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(event, endedId: endedId)
            }
        }

        engine.play()
        isPlaying = true
        updateNowPlayingInfo()

        // 再生位置をサーバーへ定期同期（15秒ごと）。
        startPlaybackPositionSync()
    }

    /// 指定 ID の Podcast を取得して再生する（通知ディープリンク用・issue #80）。
    ///
    /// 一覧に無いエピソードでも開けるよう、サーバから取得してから再生する。
    /// - Parameter id: 再生対象の Podcast ID。
    func playById(_ id: String) async {
        do {
            let podcast = try await apiClient.fetchPodcast(id: id)
            await play(podcast: podcast)
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .podcast)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - エンジン事象の適用（issue #51）

    /// エンジンの事象を `@Published` 状態へ反映する（MainActor 上で同期的に行う）。
    /// - Parameters:
    ///   - event: load 固有の stream から届いた事象。
    ///   - endedId: その load の podcast ID（`ended` の stale ガード用に load 時に閉じ込めた値）。
    private func apply(_ event: EngineEvent, endedId: String) {
        switch event {
        case .ready:
            break
        case .buffering:
            isBuffering = true
        case .resumed, .paused:
            isBuffering = false
        case .failed(let description):
            errorMessage = description ?? "Playback failed"
            isPlaying = false
        case .timeUpdate(let seconds, let itemDuration):
            currentTime = seconds
            duration = itemDuration
            // ロック画面の経過/総時間のみ軽量更新する（辞書全構築は離散イベント時のみ）。
            nowPlaying.updateElapsed(currentTime, duration: duration)
        case .ended:
            // 非構造化 Task: 購読 Task の cancel に完聴記録の送信を巻き込まない。
            Task { await self.handlePlaybackEnded(endedId: endedId) }
        case .interrupted:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { togglePlayPause() }
        case .interruptionEnded(let shouldResume):
            if shouldResume, wasPlayingBeforeInterruption, !isPlaying {
                togglePlayPause()
            }
            wasPlayingBeforeInterruption = false
        case .outputDeviceLost:
            // イヤホン抜去など旧デバイス喪失時に一時停止する。
            if isPlaying { togglePlayPause() }
        }
    }

    // MARK: - 再生キュー（issue #81）

    /// 再生終了時の自動次再生。キューに次があれば再生し、無ければ停止してプレイヤーを閉じる。
    ///
    /// - Parameter endedId: 終了通知の発火元となった podcast の ID。`nil`（既定・直接呼び出し用）なら
    ///   stale ガードは働かない。非 nil のとき、現在の `currentPodcast` と一致しなければ
    ///   （Task 実行までの隙間に利用者が別エピソードへ切り替えた stale 呼び出しとみなし）何もしない。
    func handlePlaybackEnded(endedId: String? = nil) async {
        if let endedId, currentPodcast?.id != endedId { return }
        let completedPodcastId = currentPodcast?.id

        // UI 収束をネットワーク待ちより先に確定する（await を挟むと収束が2RTT分遅れるため）。
        // play() は実質同期（内部に await ポイントを持たない）。
        if let next = queue.advance() {
            await play(podcast: next, expandsPlayer: false)
        } else {
            // キュー終端: 再生を停止しつつ currentPodcast を保持する。
            // これにより、語彙/クイズ導線が「聴き終わった」瞬間に残り、
            // 回答途中のシートが強制 dismiss されない。
            stopPlayback()
            // currentPodcast は保持（再生位置は末尾のまま、プレイヤーは一時停止状態）
            didFinishCurrentEpisode = true
        }

        // 完聴記録は best-effort（通信失敗で自動遷移や次の再生を止めない）。キュー終端では
        // 再生停止後（画面ロック中も含む）に走るため、サスペンドされないよう background task で囲う。
        // `UIBackgroundModes` は audio のみのため、これはベストエフォートの保護（expirationHandler なし）。
        if let completedPodcastId {
            let bgTask = UIApplication.shared.beginBackgroundTask()
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }
            try? await apiClient.markCompleted(id: completedPodcastId)
            await refreshListeningStreak()
        }
    }

    /// プレイヤーをミニ表示へ最小化する（フルプレイヤーシートの下スワイプ dismiss から呼ぶ）。
    func minimizePlayer() {
        guard presentation != .hidden else { return }
        presentation = .mini
    }

    /// フルプレイヤーシートを開く（ミニプレイヤーのタップから呼ぶ）。
    func expandPlayer() {
        guard currentPodcast != nil else { return }
        presentation = .expanded
    }

    /// 同じエピソードを先頭から再生し直す（「もう一度聴く」）。
    /// 表示形態は変えない（ミニの replay ボタンからも呼ばれるため）。
    func replayCurrentEpisode() async {
        guard let podcast = currentPodcast else { return }
        await play(podcast: podcast, expandsPlayer: false)
        // play() はフェッチ時の途中位置へ復元し得るため、成功時のみ明示的に先頭へ。
        guard isAudioLoaded else { return }
        seek(to: 0)
    }

#if DEBUG
    /// プレビュー専用シーム。`didFinishCurrentEpisode` は `private(set)` のため、
    /// `PreviewSupport` から finished（聴き終わりましたコンパクト表示）状態を直接組み立てられない。
    /// DEBUG ビルドのみ内部メソッドとして公開する。
    func previewMarkFinished() {
        didFinishCurrentEpisode = true
    }
#endif

    /// 現在のクイズ回答をサーバーへ送り、採点結果を返す。
    func submitQuizAnswers(podcastId: String, answers: [Int]) async throws -> QuizAnswerResponse {
        try await apiClient.submitQuizAnswers(podcastId: podcastId, answers: answers)
    }

    /// 登録済み語彙を取得する。AudioPlayerView の初期「習得済み」反映に使う。
    func fetchSavedVocabulary() async throws -> VocabularyListResponse {
        try await apiClient.fetchVocabulary()
    }

    /// 現在の Podcast グロッサリ語を個人語彙帳へ冪等登録する。
    func saveVocabulary(podcastId: String, term: String) async throws -> VocabularyItem {
        try await apiClient.saveVocabulary(podcastId: podcastId, term: term)
    }

    /// このエピソードを今すぐ再生する（一覧タップ起点）。
    /// キュー内にあればそこへジャンプ、無ければ現在の次に挿入してそこへジャンプする。
    /// WHY(#81 review): start で丸ごと置換すると利用者が組んだ待機列が消えるため、挿入方式で保持する。
    func playNow(_ podcast: Podcast) async {
        if !queue.jump(to: podcast.id) {
            queue.playNext(podcast)
            _ = queue.jump(to: podcast.id)
        }
        await play(podcast: podcast)
    }

    /// キュー末尾に追加する（「キューに追加」）。何も再生していなければ即再生を開始する。
    func addToQueue(_ podcast: Podcast) async {
        let nothingPlaying = currentPodcast == nil
        queue.add(podcast)
        if nothingPlaying {
            await playNow(podcast)
        }
    }

    /// 現在の次に割り込む（「次に再生」）。何も再生していなければ即再生を開始する。
    func playNext(_ podcast: Podcast) async {
        let nothingPlaying = currentPodcast == nil
        queue.playNext(podcast)
        if nothingPlaying {
            await playNow(podcast)
        }
    }

    /// キューから取り除く。
    func removeFromQueue(id: String) {
        queue.remove(id: id)
    }

    /// 待機列（upNext）を SwiftUI の onMove 規約で並べ替える。
    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.reorderUpNext(fromOffsets: source, toOffset: destination)
    }

    /// 再生中なら一時停止し、停止中なら再生を再開する。
    func togglePlayPause() {
        guard isAudioLoaded else { return }
        if isPlaying {
            engine.pause()
        } else {
            // pause 後の再開でも設定済みの速度を保つため rate で再生する。
            engine.setRate(playbackSpeed)
        }
        isPlaying.toggle()
        updateNowPlayingInfo()
    }

    /// 指定位置へシークする。
    /// - Parameter seconds: 移動先の再生位置（秒）。
    func seek(to seconds: Double) {
        engine.seek(to: seconds)
        currentTime = seconds
        updateNowPlayingInfo()
    }

    /// 再生速度を設定する。再生中なら即座に反映する。
    /// - Parameter speed: 再生速度（倍率）。
    func setSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying { engine.setRate(speed) }
        updateNowPlayingInfo()
    }

    /// 再生を停止し、エンジン・事象購読・再生状態を解放/リセットする。
    /// 同期完了を試みてからシャットダウンする。
    func stopPlayback() {
        // 再生位置を最後に同期しておく。
        syncPlaybackPositionIfNeeded()
        tearDownPlayback()
    }

    /// エンジン・事象購読・再生状態を解放/リセットする（位置同期は行わない: D-4）。
    /// `stopPlayback()`（同期あり）と `stopForLogout()`（同期なし・TP4）の共通部分。
    private func tearDownPlayback() {
        // タイマーを停止。
        syncTimer?.invalidate()
        syncTimer = nil

        // 購読 Task を先に cancel してから engine を止める（止めた後に前の load の事象を適用しない）。
        engineEventTask?.cancel()
        engineEventTask = nil
        engine.stop()
        isAudioLoaded = false
        isPlaying = false
        currentTime = 0
        duration = 0
        isBuffering = false
        wasPlayingBeforeInterruption = false

        // ロック画面/コントロールセンターの再生情報を消す。
        nowPlaying.clear()
    }

    // MARK: - Background Playback (Now Playing / Remote Command / 割り込み)

    /// ロック画面/コントロールセンター操作を一度だけ登録する。
    /// 再生のたびに呼ばれるが、多重登録を避けるため token の有無で初回のみ実行する。
    /// 割り込み・route change はエンジンが事象として届ける。
    private func configureBackgroundPlayback() {
        guard remoteCommandRegistration == nil else { return }
        remoteCommandRegistration = nowPlaying.registerCommands { [weak self] command in
            guard let self else { return .commandFailed }
            return self.handleRemoteCommand(command)
        }
    }

    /// リモートコマンドを ViewModel の操作へ配線する。読み込み前は no-op で、コマンドごとの固定値を返す。
    private func handleRemoteCommand(_ command: RemoteCommand) -> RemoteCommandResult {
        switch command {
        case .play:
            guard isAudioLoaded else { return .noSuchContent }
            if !isPlaying { togglePlayPause() }
        case .pause:
            guard isAudioLoaded else { return .noSuchContent }
            if isPlaying { togglePlayPause() }
        case .togglePlayPause:
            guard isAudioLoaded else { return .noSuchContent }
            togglePlayPause()
        case .skipBackward:
            guard isAudioLoaded else { return .noSuchContent }
            seek(to: max(0, currentTime - PlaybackConstants.skipBackwardSeconds))
        case .skipForward:
            guard isAudioLoaded else { return .noSuchContent }
            seek(to: min(duration, currentTime + PlaybackConstants.skipForwardSeconds))
        case .changePosition(let seconds):
            guard isAudioLoaded else { return .commandFailed }
            seek(to: seconds)
        case .changeRate(let rate):
            guard isAudioLoaded else { return .noSuchContent }
            setSpeed(rate)
        }
        return .success
    }

    /// 現在の再生状態をロック画面に反映する。再生対象が無ければ消す。
    /// タイトル・難易度などを含む辞書を全構築するため、再生/一時停止・シーク・速度変更などの
    /// 離散イベント時に呼ぶ（高頻度の経過更新は `nowPlaying.updateElapsed` を使う）。
    private func updateNowPlayingInfo() {
        guard let podcast = currentPodcast else {
            nowPlaying.clear()
            return
        }
        nowPlaying.update(NowPlayingInfo.make(
            podcast: podcast,
            elapsed: currentTime,
            duration: duration,
            rate: playbackSpeed,
            isPlaying: isPlaying
        ))
    }

    deinit {
        // 購読 Task の cancel と、自分の token の解除だけを行う（どちらもスレッド安全）。
        // 解除は token 単位なので、再ログイン後の別 VM の登録は外さない。
        engineEventTask?.cancel()
        if let registration = remoteCommandRegistration {
            nowPlaying.unregister(registration)
        }
    }

    // MARK: - Playback Position Sync

    /// 再生位置をサーバーへ定期同期するタイマーを開始する。
    /// 再生位置を 15 秒ごとにサーバーへ同期する。
    private func startPlaybackPositionSync() {
        // 既に起動していれば何もしない。
        guard syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            // タイマーは @MainActor 文脈の本メソッドからメインランループへ登録され発火もメインで
            // 行われるため、既存の Observer 同様 assumeIsolated で @MainActor 隔離を明示する。
            MainActor.assumeIsolated {
                self?.syncPlaybackPositionIfNeeded()
            }
        }
    }

    /// 現在の再生位置を即時にサーバーへ同期する（再生状態は変更しない）。
    ///
    /// タブ間再生継続によりタブ離脱では stopPlayback() を呼ばなくなったため、
    /// アプリのバックグラウンド遷移（scenePhase）時の取りこぼし防止として View 層から呼ぶ。
    func flushPlaybackPosition() {
        syncPlaybackPositionIfNeeded()
    }

    /// 現在の再生位置をサーバーへ同期する。
    /// currentPodcast が nil の場合や通信失敗時はサイレント失敗。
    ///
    /// WHY(#50): `currentTime` は Task 生成前にここで捕捉する。`stopPlayback()` は本メソッドの
    /// 直後に `currentTime = 0` へリセットするため、Task 内で `self.currentTime` を読むと
    /// MainActor 上で後発実行される Task は常に 0 を送ってしまい、停止直前の再生位置が
    /// 0 で上書きされ resume が壊れていた。
    private func syncPlaybackPositionIfNeeded() {
        guard let podcast = currentPodcast else { return }
        let position = currentTime
        Task {
            do {
                _ = try await apiClient.updatePlaybackPosition(podcastId: podcast.id, positionSeconds: position)
            } catch {
                // 同期失敗時はログしない（ネットワーク一時的な失敗等を避けるため）。
            }
        }
    }
}

// MARK: - PlaybackLifecycle（TP4）

extension PodcastViewModel: PlaybackLifecycle {
    /// TP4（owner: user／導入: I-S2 2026-09-28／削除条件: I-S3b2 で `PlaybackCoordinator` が
    /// `PlaybackLifecycle` の実装を引き継いだ時点。コードの物理削除は I-S3b3）。
    ///
    /// 主体離脱時の再生停止。位置同期は送らない（D-4・C1: `stopPlayback()` の同期部分を呼ばない）。
    /// 冪等（2 回呼んでも同じ状態・送信 0）。
    func stopForLogout() {
        tearDownPlayback()
        currentPodcast = nil
        queue = PlaybackQueue()
        presentation = .hidden
        didFinishCurrentEpisode = false
    }
}
