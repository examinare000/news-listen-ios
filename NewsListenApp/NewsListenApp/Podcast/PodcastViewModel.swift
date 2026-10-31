//
//  PodcastViewModel.swift
//  NewsListenApp
//
//  Podcast タブの facade。一覧と学習の操作を持ち、再生・保存は `PlaybackCoordinator`・`OfflineDownloads`・
//  `OfflineLibrary` へ中継する。再生の判断はここに書かない。
//

import Foundation
import Combine

/// Podcast タブの状態とロジックを担う ViewModel（facade）。
///
/// 責務は、Coordinator の中継、一覧の状態、学習の中継、alert の文言の合成、行のバッジの種類の 5 つ。
///
/// - Note: 既存の構成を保つため `NSObject` を継承する。
@MainActor
final class PodcastViewModel: NSObject, ObservableObject {
    /// 行のバッジの種類。ios-temp-06 の間だけ（ios-slice-catalog-01 で `EpisodeBadge` に替わる）。
    enum RowBadge: Equatable {
        case none
        case generating
        case failed
    }

    /// 表示中の Podcast 一覧。
    @Published private(set) var podcasts: [Podcast] = []
    /// 読み込み中かどうか。
    @Published private(set) var isLoading = false
    /// 一覧側の操作（一覧読込・保存・削除・通知からの再生）の失敗。再生由来の失敗は `notice` が持つ。
    @Published private(set) var listErrorMessage: String?
    /// 現在ネットワークがオンラインかどうか（オフラインバナー表示用に View から購読する・issue #54）。
    @Published private(set) var isOnline: Bool

    /// Coordinator の同名の値の写し（facade は書かない）。
    @Published private(set) var session: PlaybackState = .idle
    @Published private(set) var presentation: PlayerPresentation = .hidden
    @Published private(set) var notice: PlaybackNotice?

    /// 主体離脱時の再生停止 port（実体は Coordinator）。
    let playbackLifecycle: any PlaybackLifecycle

    private let apiClient: APIClient
    private let coordinator: PlaybackCoordinator
    private let positionReporter: PositionReporter
    private let library: OfflineLibrary
    private let downloads: OfflineDownloads
    private let defaultSpeed: () -> Float
    private var cancellables = Set<AnyCancellable>()

    /// - Parameters:
    ///   - apiClient: 一覧と学習の通信に使うクライアント。
    ///   - coordinator: 再生の入口。
    ///   - reporter: `flushPosition()` のためだけに持つ。外へ出さない。
    ///   - library: 保存済み音声の集合。
    ///   - downloads: オフライン保存の use case。
    ///   - networkMonitor: ネットワーク監視（オフラインバナー用）。
    ///   - defaultSpeed: 再生していないときの速度の表示（`playbackSpeed` の fallback）。
    init(
        apiClient: APIClient,
        coordinator: PlaybackCoordinator,
        reporter: PositionReporter,
        library: OfflineLibrary,
        downloads: OfflineDownloads,
        networkMonitor: NetworkMonitoring,
        defaultSpeed: @escaping () -> Float
    ) {
        self.apiClient = apiClient
        self.coordinator = coordinator
        self.positionReporter = reporter
        self.library = library
        self.downloads = downloads
        self.defaultSpeed = defaultSpeed
        self.playbackLifecycle = coordinator
        self.isOnline = networkMonitor.isOnline
        // NSObject 継承のため、`$isOnline` 等 self を用いるプロパティラッパアクセスは
        // super.init() 完了後でなければならない。
        super.init()
        networkMonitor.isOnlinePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)
        coordinator.$session.assign(to: &$session)
        coordinator.$presentation.assign(to: &$presentation)
        coordinator.$notice.assign(to: &$notice)
        // 再生を始めたら、前回の一覧側の失敗を消す（issue #58）。
        coordinator.$session
            .sink { [weak self] state in
                if case .loading = state { self?.listErrorMessage = nil }
            }
            .store(in: &cancellables)
        // `nowPlaying()`・`upNext()`・`downloadState(for:)` は読み取りなので、元の変化で View を再描画させる。
        coordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        library.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        downloads.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - 表示の合成

    /// 表示するエラー。再生の通知があればそれ、無ければ一覧側の失敗。
    var errorMessage: String? {
        if let notice { return Self.message(for: notice) }
        return listErrorMessage
    }

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

    /// alert に出す文言。出す条件（`shouldPresentErrorAlert`）を満たさないときは nil。
    var alertMessage: String? { shouldPresentErrorAlert ? errorMessage : nil }

    /// 聴き終えて、次へ自動で進む途中でもないか。
    var isFinished: Bool {
        session.isEnded && !coordinator.isAdvancing
    }

    static func message(for notice: PlaybackNotice) -> String {
        switch notice {
        case .failure(let reason): return playbackErrorMessage(for: reason)
        case .loadWarning(let description): return description
        }
    }

    static func playbackErrorMessage(for reason: PlaybackErrorReason) -> String {
        switch reason {
        case .offlineUncached: return "Offline and not cached"
        case .invalidSource: return "Invalid audio URL"
        case .engineFailed(let description): return description ?? "Playback failed"
        case .fetchFailed(let failure): return FailureMessages.message(for: failure, context: .podcast)
        }
    }

    // MARK: - 再生の表示値（Coordinator の状態からの導出）

    var isPlaying: Bool {
        switch session {
        case .loading, .playing, .buffering: return true
        case .idle, .paused, .ended, .errored: return false
        }
    }

    var isBuffering: Bool {
        if case .buffering = session { return true }
        return false
    }

    var playbackSpeed: Float { session.speed ?? defaultSpeed() }

    // MARK: - Data

    /// Podcast 一覧を取得して `podcasts` を更新する。失敗時は `listErrorMessage` に反映する。
    /// 始めに一覧側と再生由来のエラーの両方を消し、終わりに保存済みの集合を一覧に合わせて更新する。
    func loadPodcasts() async {
        isLoading = true
        dismissError()
        do {
            let response = try await apiClient.fetchPodcasts()
            podcasts = response.podcasts
            library.refresh(candidateIds: podcasts.map(\.id))
        } catch let f as ApiFailure {
            listErrorMessage = FailureMessages.message(for: f, context: .podcast)
        } catch {
            listErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 位置の保存の応答で、一覧の同じ id の要素を置き換える（無ければ何もしない）。
    func replacePodcast(_ podcast: Podcast) {
        guard let index = podcasts.firstIndex(where: { $0.id == podcast.id }) else { return }
        podcasts[index] = podcast
    }

    func dismissError() {
        listErrorMessage = nil
        coordinator.dismissError()
    }

    func rowBadge(for podcast: Podcast) -> RowBadge {
        switch podcast.toEpisode() {
        case .playable: return .none
        case .generating: return .generating
        case .failed: return .failed
        }
    }

    // MARK: - ダウンロード

    /// 指定 Podcast の保存状態。
    func downloadState(for podcastId: String) -> DownloadState {
        downloads.state(for: podcastId)
    }

    /// オフライン時、指定のダウンロード状態が再生可能かどうかを返す（一覧の視覚的区別に使用・issue #54）。
    /// ダウンロード済みのみ再生可能。純粋関数（副作用なし・テスト容易）。
    static func isPlayableWhileOffline(downloadState: DownloadState) -> Bool {
        downloadState == .downloaded
    }

    func download(podcast: Podcast) async {
        do {
            try await downloads.download(episodeId: podcast.id)
        } catch {
            recordListFailure(error)
        }
    }

    func removeDownload(podcast: Podcast) async {
        do {
            try downloads.remove(episodeId: podcast.id)
        } catch {
            recordListFailure(error)
        }
    }

    // MARK: - 再生の中継

    func startEpisode(_ podcast: Podcast, expandsPlayer: Bool = true) async {
        await coordinator.startEpisode(podcast.toEpisode(), expandsPlayer: expandsPlayer)
    }

    func startEpisode(id: String) async {
        do {
            try await coordinator.startEpisode(id: id)
        } catch {
            recordListFailure(error)
        }
    }

    func replayCurrent() async { await coordinator.replayCurrent() }

    func retry() async { await coordinator.retry() }

    func togglePlayPause() { coordinator.togglePlayPause() }

    func seek(to seconds: Double) { coordinator.seek(to: seconds) }

    func setSpeed(_ speed: Float) { coordinator.setSpeed(speed) }

    func addToQueue(_ podcast: Podcast) async { await coordinator.addToQueue(podcast.toEpisode()) }

    func playNext(_ podcast: Podcast) async { await coordinator.playNext(podcast.toEpisode()) }

    func removeFromQueue(id: String) { coordinator.removeFromQueue(id: id) }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        coordinator.moveUpNext(fromOffsets: source, toOffset: destination)
    }

    func skipToNext() async { await coordinator.skipToNext() }

    func nowPlaying() -> NowPlaying? { coordinator.nowPlaying() }

    func upNext() -> [QueueEntry] { coordinator.upNext() }

    func minimizePlayer() { coordinator.minimizePlayer() }

    func expandPlayer() { coordinator.expandPlayer() }

    func stop() { coordinator.stop() }

    /// 背景遷移などの直前に、現在の位置を送る。
    func flushPosition() { positionReporter.flush() }

    // MARK: - 学習

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

    // MARK: - 一覧側の失敗

    /// cancel は何も書かない（`CancellationError`・`URLError` の `.cancelled`）。
    private func recordListFailure(_ error: Error) {
        if let message = listMessage(for: error) { listErrorMessage = message }
    }

    private func listMessage(for error: Error) -> String? {
        if let failure = error as? DownloadFailure {
            switch failure {
            case .api(let apiFailure): return FailureMessages.message(for: apiFailure, context: .podcast)
            case .invalidSource: return "Invalid audio URL"
            case .store(let description): return description
            }
        }
        if let apiFailure = error as? ApiFailure {
            return FailureMessages.message(for: apiFailure, context: .podcast)
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
        return error.localizedDescription
    }
}

// MARK: - 主体離脱

extension PodcastViewModel {
    /// 主体離脱時の再生停止。位置は送らない。冪等。
    func stopForLogout() {
        coordinator.stopForLogout()
    }
}
