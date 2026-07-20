import XCTest
import AVFoundation
@testable import NewsListenApp

// PodcastViewModel は @MainActor 分離（AVPlayer 操作を含む）のため、
// テストクラスも @MainActor にして init / メソッド呼び出しの分離コンテキストを揃える。
@MainActor
final class PodcastViewModelTests: XCTestCase {

    // ファクトリヘルパー：新しい init シグネチャに対応
    private func makeViewModel(
        apiClient: APIClient,
        cacheManager: AudioCacheManager? = nil,
        networkMonitor: NetworkMonitoring? = nil
    ) -> PodcastViewModel {
        let cache = cacheManager ?? AudioCacheManager(fileManager: MockFileManager())
        let network = networkMonitor ?? StubNetworkMonitor()
        return PodcastViewModel(apiClient: apiClient, cacheManager: cache, networkMonitor: network)
    }

    // MARK: - issue #81: 再生キュー（連続再生）

    private func queuePodcast(_ id: String) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/\(id).mp3", title: "",
            japaneseIntroText: "i",
            durationSeconds: 60, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
    }

    private func makeOnlineViewModel() -> PodcastViewModel {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(data: Data("{}".utf8), statusCode: 200)
        )
        return makeViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: true))
    }

    func testAddToQueueStartsPlaybackWhenIdle() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        XCTAssertEqual(vm.currentPodcast?.id, "a")
        XCTAssertEqual(vm.queue.current?.id, "a")
    }

    func testAutoAdvancePlaysNextOnEnd() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))   // a を再生
        await vm.addToQueue(queuePodcast("b"))   // b をキュー
        await vm.handlePlaybackEnded()           // a 終了 → 自動で b へ
        XCTAssertEqual(vm.queue.current?.id, "b")
        XCTAssertEqual(vm.currentPodcast?.id, "b")
    }

    func testStopsWhenQueueExhaustedOnEnd() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))   // a を再生（キューは [a] のみ）
        await vm.handlePlaybackEnded()           // 次が無い → 停止
        XCTAssertNil(vm.currentPodcast)
        XCTAssertFalse(vm.isPlaying)
    }

    func testPlayNextInsertsAfterCurrent() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))   // a を再生
        await vm.addToQueue(queuePodcast("b"))   // [a, b]
        await vm.playNext(queuePodcast("c"))     // a の次に c

        XCTAssertEqual(vm.queue.upNext.map { $0.id }, ["c", "b"])
    }

    func testRemoveFromQueue() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        await vm.addToQueue(queuePodcast("b"))

        vm.removeFromQueue(id: "b")
        XCTAssertEqual(vm.queue.items.map { $0.id }, ["a"])
    }

    func testLoadPodcastsPopulatesList() async throws {
        let mockJSON = #"""
        {"podcasts": [
            {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"}
        ]}
        """#.data(using: .utf8)!

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client)

        await vm.loadPodcasts()

        XCTAssertEqual(vm.podcasts.count, 1)
        XCTAssertEqual(vm.podcasts[0].id, "p1")
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadPodcastsSetsErrorMessageOnFailure() async throws {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 500)
        )
        let vm = makeViewModel(apiClient: client)

        await vm.loadPodcasts()

        XCTAssertTrue(vm.podcasts.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - issue #53: ロード失敗と「本当に空」の空状態を区別する

    func testDisplayStateIsErrorWhenLoadPodcastsFailsWithEmptyList() async throws {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 500)
        )
        let vm = makeViewModel(apiClient: client)

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
    }

    func testDisplayStateIsContentWhenLoadPodcastsFailsButListRemains() async throws {
        // リフレッシュ失敗時は既存の一覧を残す。その場合は空状態ではなく一覧を優先して表示する。
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 500)
        )
        let vm = makeViewModel(apiClient: client)
        vm.podcasts = [queuePodcast("p1")]

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .content)
    }

    func testDisplayStateIsEmptyWhenLoadPodcastsSucceedsWithNoPodcasts() async throws {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(#"{"podcasts": []}"#.utf8), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client)

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .empty)
    }

    func testDisplayStateIsLoadingWhileInitialLoadInProgress() {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client)
        vm.isLoading = true

        XCTAssertEqual(vm.displayState, .loading)
    }

    func testSetSpeedUpdatesPlaybackSpeed() {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client)

        vm.setSpeed(1.5)

        XCTAssertEqual(vm.playbackSpeed, 1.5)
    }

    // MARK: - T4: resolvePlaybackURL

    func testResolvePlaybackURLReturnsCachedURL() {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let mockFile = MockFileManager()
        mockFile.directories.insert("/mock-caches/NewsListenApp/audio-cache")
        let cache = AudioCacheManager(fileManager: mockFile)

        // キャッシュにファイルを追加
        try? mockFile.write("audio".data(using: .utf8)!, to: cache.cachedURL(for: "p1"))

        let url = PodcastViewModel.resolvePlaybackURL(for: podcast, isOnline: true, cacheManager: cache)

        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.hasSuffix("audio-cache/p1.mp3"))
    }

    func testResolvePlaybackURLReturnsAudioURLWhenOnlineNoCached() {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let mockFile = MockFileManager()
        let cache = AudioCacheManager(fileManager: mockFile)

        let url = PodcastViewModel.resolvePlaybackURL(for: podcast, isOnline: true, cacheManager: cache)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://storage.example.com/p1.mp3")
    }

    func testResolvePlaybackURLReturnsNilOfflineNoCached() {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let mockFile = MockFileManager()
        let cache = AudioCacheManager(fileManager: mockFile)

        let url = PodcastViewModel.resolvePlaybackURL(for: podcast, isOnline: false, cacheManager: cache)

        XCTAssertNil(url)
    }

    // MARK: - T5: Download & State

    func testDownloadFetchesPodcastAndCachesAudio() async throws {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )

        // fetchPodcast のレスポンス（署名付き新鮮な audioUrl）
        let freshPodcastJSON = #"""
        {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1-signed.mp3?token=xxx","japanese_intro_text":"test","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"}
        """#.data(using: .utf8)!
        let audioData = "mock audio content".data(using: .utf8)!

        let mockSession = MockDownloadSession(responses: [
            .podcast: freshPodcastJSON,
            .audio: audioData
        ])

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let mockFile = MockFileManager()
        mockFile.directories.insert("/mock-caches")
        mockFile.directories.insert("/mock-caches/NewsListenApp")
        mockFile.directories.insert("/mock-caches/NewsListenApp/audio-cache")
        let cache = AudioCacheManager(fileManager: mockFile)

        let vm = makeViewModel(apiClient: client, cacheManager: cache)

        await vm.download(podcast: podcast)

        XCTAssertTrue(vm.downloadedIds.contains("p1"))
        XCTAssertFalse(vm.downloadingIds.contains("p1"))
    }

    func testDownloadStateReturnsCorrectState() {
        // 純粋関数を直接検証する（private(set) の状態を外から壊さない）。
        XCTAssertEqual(
            PodcastViewModel.downloadState(forId: "p1", downloaded: [], downloading: []),
            .notDownloaded
        )
        XCTAssertEqual(
            PodcastViewModel.downloadState(forId: "p1", downloaded: [], downloading: ["p1"]),
            .downloading
        )
        XCTAssertEqual(
            PodcastViewModel.downloadState(forId: "p1", downloaded: ["p1"], downloading: []),
            .downloaded
        )
        // downloading が downloaded より優先される。
        XCTAssertEqual(
            PodcastViewModel.downloadState(forId: "p1", downloaded: ["p1"], downloading: ["p1"]),
            .downloading
        )
    }

    func testSyncDownloadedState() async throws {
        let mockJSON = #"""
        {"podcasts": [
            {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"test","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"},
            {"id":"p2","type":"single","article_ids":["a2"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p2.mp3","japanese_intro_text":"test2","duration_seconds":200,"created_at":"2026-05-30T06:00:00Z","status":"completed"}
        ]}
        """#.data(using: .utf8)!

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )

        let mockFile = MockFileManager()
        mockFile.directories.insert("/mock-caches/NewsListenApp/audio-cache")
        let cache = AudioCacheManager(fileManager: mockFile)

        // p1 をキャッシュに追加
        try? mockFile.write("audio".data(using: .utf8)!, to: cache.cachedURL(for: "p1"))

        let vm = makeViewModel(apiClient: client, cacheManager: cache)

        await vm.loadPodcasts()

        // syncDownloadedState は loadPodcasts の末尾で呼ばれる
        XCTAssertTrue(vm.downloadedIds.contains("p1"))
        XCTAssertFalse(vm.downloadedIds.contains("p2"))
    }

    // MARK: - T6: play()

    func testPlayOfflineNoCachedSetsErrorMessage() async throws {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )

        let mockFile = MockFileManager()
        let cache = AudioCacheManager(fileManager: mockFile)
        let offline = StubNetworkMonitor(isOnline: false)

        let vm = makeViewModel(apiClient: client, cacheManager: cache, networkMonitor: offline)

        await vm.play(podcast: podcast)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.currentPodcast)
    }

    func testPlayOnlineNoCachedResolvesAudioURL() async throws {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )

        let mockFile = MockFileManager()
        let cache = AudioCacheManager(fileManager: mockFile)
        let online = StubNetworkMonitor(isOnline: true)

        let vm = makeViewModel(apiClient: client, cacheManager: cache, networkMonitor: online)

        await vm.play(podcast: podcast)

        // オンライン + キャッシュなし = 再生開始（currentPodcast = podcast）
        XCTAssertEqual(vm.currentPodcast?.id, "p1")
    }

    // MARK: - issue #58: play() 成功時に前回のエラーメッセージを持ち越さない

    func testPlaySuccessClearsStaleErrorMessage() async throws {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let mockFile = MockFileManager()
        let cache = AudioCacheManager(fileManager: mockFile)
        let online = StubNetworkMonitor(isOnline: true)
        let vm = makeViewModel(apiClient: client, cacheManager: cache, networkMonitor: online)
        // 前回の再生失敗が残っている状態を再現する。
        vm.errorMessage = "前回の再生に失敗しました"

        await vm.play(podcast: podcast)

        XCTAssertNil(vm.errorMessage)
    }

    func testPlayOfflineNoCachedOverwritesStaleErrorMessage() async throws {
        // ガードに引っかかる経路では、クリアより前に新しいメッセージが設定されること
        // （クリアを挿入した際に既存のガード動作を壊していないこと）を確認する。
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let mockFile = MockFileManager()
        let cache = AudioCacheManager(fileManager: mockFile)
        let offline = StubNetworkMonitor(isOnline: false)
        let vm = makeViewModel(apiClient: client, cacheManager: cache, networkMonitor: offline)
        vm.errorMessage = "前回の別のエラー"

        await vm.play(podcast: podcast)

        XCTAssertEqual(vm.errorMessage, "Offline and not cached")
    }

    // MARK: - issue #58: インラインエラー表示（displayState .error）とアラートの二重表示防止

    func testShouldPresentErrorAlertFalseWhenListEmptyAndDisplayStateIsError() async throws {
        // 一覧が空でロード失敗＝インラインエラー表示中は、同じエラーのアラートを重ねて出さない。
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 500)
        )
        let vm = makeViewModel(apiClient: client)

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertTrueWhenListNonEmptyAndErrorMessageSet() async throws {
        // 一覧が非空のまま発生したエラー（再生失敗等）はインライン表示が無いのでアラートを出す。
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client)
        vm.podcasts = [queuePodcast("p1")]
        vm.errorMessage = "再生に失敗しました"

        XCTAssertEqual(vm.displayState, .content)
        XCTAssertTrue(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertFalseWhenNoErrorMessage() {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client)

        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    // MARK: - リモートコマンド経路と同じ再生制御メソッドの状態遷移（issue #79）

    private func playingViewModel() async -> PodcastViewModel {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: 200)
        )
        let cache = AudioCacheManager(fileManager: MockFileManager())
        let vm = makeViewModel(apiClient: client, cacheManager: cache, networkMonitor: StubNetworkMonitor(isOnline: true))
        await vm.play(podcast: podcast)
        return vm
    }

    func testTogglePlayPauseFlipsIsPlayingAfterPlay() async throws {
        let vm = await playingViewModel()
        XCTAssertTrue(vm.isPlaying)

        // ロック画面の一時停止コマンドは togglePlayPause を経由する。
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)

        vm.togglePlayPause()
        XCTAssertTrue(vm.isPlaying)
    }

    func testSeekUpdatesCurrentTimeAfterPlay() async throws {
        let vm = await playingViewModel()

        // スキップコマンドは seek(to:) を経由する。
        vm.seek(to: 42)
        XCTAssertEqual(vm.currentTime, 42)
    }

    func testSetSpeedUpdatesPlaybackSpeedAfterPlay() async throws {
        let vm = await playingViewModel()

        // 速度変更コマンドは setSpeed(_:) を経由する。
        vm.setSpeed(1.75)
        XCTAssertEqual(vm.playbackSpeed, 1.75)
    }

    func testStopPlaybackResetsState() async throws {
        let vm = await playingViewModel()

        vm.stopPlayback()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentTime, 0)
    }

    // MARK: - issue #54: オフライン時の事前無効化

    func testIsOnlineReflectsInjectedNetworkMonitor() {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(data: Data("{}".utf8), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: false))

        XCTAssertFalse(vm.isOnline)
    }

    func testIsPlayableWhileOfflineTrueOnlyWhenDownloaded() {
        XCTAssertTrue(PodcastViewModel.isPlayableWhileOffline(downloadState: .downloaded))
        XCTAssertFalse(PodcastViewModel.isPlayableWhileOffline(downloadState: .downloading))
        XCTAssertFalse(PodcastViewModel.isPlayableWhileOffline(downloadState: .notDownloaded))
    }

    // MARK: - T7: AVPlayer 状態監視（issue #51: ストリーミング失敗検出とバッファリング表示）

    func testHandlePlayerItemStatusChangeFailedSetsErrorMessageAndStopsPlaying() async throws {
        let vm = await playingViewModel()

        vm.handlePlayerItemStatusChange(.failed, errorDescription: "The network connection was lost")

        XCTAssertEqual(vm.errorMessage, "The network connection was lost")
        XCTAssertFalse(vm.isPlaying)
    }

    func testHandlePlayerItemStatusChangeFailedUsesDefaultMessageWhenDescriptionMissing() async throws {
        let vm = await playingViewModel()

        vm.handlePlayerItemStatusChange(.failed, errorDescription: nil)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isPlaying)
    }

    func testHandlePlayerItemStatusChangeIgnoresNonFailedStatus() async throws {
        let vm = await playingViewModel()

        vm.handlePlayerItemStatusChange(.readyToPlay, errorDescription: nil)

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.isPlaying)
    }

    func testHandleTimeControlStatusChangeWaitingSetsIsBuffering() async throws {
        let vm = await playingViewModel()
        XCTAssertFalse(vm.isBuffering)

        vm.handleTimeControlStatusChange(.waitingToPlayAtSpecifiedRate)

        XCTAssertTrue(vm.isBuffering)
    }

    func testHandleTimeControlStatusChangePlayingClearsIsBuffering() async throws {
        let vm = await playingViewModel()
        vm.handleTimeControlStatusChange(.waitingToPlayAtSpecifiedRate)
        XCTAssertTrue(vm.isBuffering)

        vm.handleTimeControlStatusChange(.playing)

        XCTAssertFalse(vm.isBuffering)
    }

    func testStopPlaybackResetsIsBuffering() async throws {
        let vm = await playingViewModel()
        vm.handleTimeControlStatusChange(.waitingToPlayAtSpecifiedRate)
        XCTAssertTrue(vm.isBuffering)

        vm.stopPlayback()

        XCTAssertFalse(vm.isBuffering)
    }

    // MARK: - issue #50: stopPlayback 時の再生位置同期が 0 で上書きされる不具合

    func testStopPlaybackSyncsPositionAtStopTimeNotZero() async throws {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", title: "",
            japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0, segments: nil
        )
        let mockSession = MockURLSession(data: Data(), statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )
        let vm = makeViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: true))
        await vm.play(podcast: podcast)
        vm.seek(to: 42)

        vm.stopPlayback()

        // syncPlaybackPositionIfNeeded は非同期 Task で送信するため、完了を少し待つ。
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/podcasts/p1/position")
        let body = try XCTUnwrap(mockSession.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Double])
        XCTAssertEqual(json["position_seconds"], 42)
    }
}

// MARK: - Mock FileManager & URLSession

extension PodcastViewModelTests {
    final class MockFileManager: FileManagerProtocol {
        var files: [String: Data] = [:]
        var directories: Set<String> = []

        func fileExists(atPath: String) -> Bool {
            files[atPath] != nil || directories.contains(atPath)
        }

        func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
            directories.insert(at.path)
        }

        func removeItem(at: URL) throws {
            files.removeValue(forKey: at.path)
        }

        func write(_ data: Data, to: URL) throws {
            files[to.path] = data
        }

        func fileSize(atPath: String) -> Int64? {
            files[atPath]?.count.int64 ?? nil
        }

        func cachesDirectory() -> URL {
            URL(fileURLWithPath: "/mock-caches")
        }

        func contentsOfDirectory(atPath path: String) throws -> [String] {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return files.keys.compactMap { key in
                guard key.hasPrefix(prefix) else { return nil }
                let name = String(key.dropFirst(prefix.count))
                return name.contains("/") ? nil : name
            }
        }
    }

    enum MockDownloadRequestType {
        case podcast
        case audio
    }

    final class MockDownloadSession: URLSessionProtocol {
        let responses: [MockDownloadRequestType: Data]
        var lastRequest: URLRequest?
        private var callCount = 0

        init(responses: [MockDownloadRequestType: Data]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lastRequest = request
            defer { callCount += 1 }

            // 1回目：fetchPodcast（/podcasts/...）
            if callCount == 0, request.url?.path.starts(with: "/podcasts") == true {
                let data = responses[.podcast] ?? Data()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }

            // 2回目：downloadAudio（https://storage.example.com/...）
            if callCount == 1 {
                let data = responses[.audio] ?? Data()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }

            // フォールバック
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }
}
