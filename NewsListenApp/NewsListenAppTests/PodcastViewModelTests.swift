import XCTest
import AVFoundation
import os
@testable import NewsListenApp

// PodcastViewModel は @MainActor 分離（AVPlayer 操作を含む）のため、
// テストクラスも @MainActor にして init / メソッド呼び出しの分離コンテキストを揃える。
@MainActor
final class PodcastViewModelTests: XCTestCase {

    // WHY: 完了ハンドラの順序入れ替え（PodcastViewModel §handlePlaybackEnded）以降、
    //      markCompleted と stopPlayback() 由来の /position 同期 Task が並行して
    //      `data(for:)` を呼び得るため、`requests` への追記を `OSAllocatedUnfairLock` で直列化する
    //      （actor 化すると呼び出し側の同期アクセス `session.requests.last` が壊れるため不採用。
    //      `NSLock` は async 文脈からの直接呼び出しが Swift 6 で警告/エラーになるため使わない）。
    private final class RequestRecordingSession: URLSessionProtocol {
        private let storage = OSAllocatedUnfairLock(initialState: [URLRequest]())
        var requests: [URLRequest] { storage.withLock { $0 } }
        let statusCode: Int

        init(statusCode: Int = 200) {
            self.statusCode = statusCode
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            storage.withLock { $0.append(request) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("{}".utf8), response)
        }
    }

    // ファクトリヘルパー：新しい init シグネチャに対応
    private func makeViewModel(
        apiClient: APIClient,
        cacheManager: AudioCacheManager? = nil,
        networkMonitor: NetworkMonitoring? = nil,
        refreshListeningStreak: @escaping @MainActor () async -> Void = {}
    ) -> PodcastViewModel {
        let cache = cacheManager ?? AudioCacheManager(fileManager: MockFileManager())
        let network = networkMonitor ?? StubNetworkMonitor()
        return PodcastViewModel(
            apiClient: apiClient,
            cacheManager: cache,
            networkMonitor: network,
            refreshListeningStreak: refreshListeningStreak
        )
    }

    // MARK: - issue #81: 再生キュー（連続再生）

    // WHY: 位置復元テスト（末尾/途中/duration=0 境界）で playbackPositionSeconds / durationSeconds を
    //      個別に指定する必要があるため、既定値付き引数へ拡張する（既存呼び出しは無変更で通る）。
    private func queuePodcast(
        _ id: String,
        playbackPositionSeconds: Double = 0,
        durationSeconds: Int = 60
    ) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/\(id).mp3", title: "",
            japaneseIntroText: "i",
            durationSeconds: durationSeconds, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: playbackPositionSeconds, segments: nil
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
        await vm.handlePlaybackEnded()           // 次が無い → 停止しつつ currentPodcast は保持
        XCTAssertEqual(vm.currentPodcast?.id, "a")
        XCTAssertFalse(vm.isPlaying)
        XCTAssertTrue(vm.didFinishCurrentEpisode)
    }

    func testPlaybackEndedPreservesPodcastForQuizWhenQueueExhausted() async {
        let vm = makeOnlineViewModel()
        let podcast = queuePodcast("completed-podcast")
        await vm.addToQueue(podcast)

        await vm.handlePlaybackEnded()

        // 自然終端後も currentPodcast が保持されているため、語彙/クイズ導線が残る
        XCTAssertEqual(vm.currentPodcast?.id, "completed-podcast")
        // 再生は停止
        XCTAssertFalse(vm.isPlaying)
        // キューは末尾要素を指したまま（再聴・ジャンプ可能な状態を保つ）
        XCTAssertEqual(vm.queue.current?.id, "completed-podcast")
        XCTAssertTrue(vm.didFinishCurrentEpisode)
    }

    func testPlaybackEndedMarksCapturedPodcastBeforeAutoAdvanceAndRefreshesStreak() async throws {
        let session = RequestRecordingSession()
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        var refreshCount = 0
        var completedSentBeforeRefresh = false
        let vm = makeViewModel(
            apiClient: client,
            networkMonitor: StubNetworkMonitor(isOnline: true),
            refreshListeningStreak: {
                refreshCount += 1
                // WHY: /position 同期 Task が並行して混ざり得るため requests.last では
                //      順序依存になる。「refresh 時点で /completed が送信済み」という
                //      本来の順序保証だけを内容ベースで捕捉する。
                completedSentBeforeRefresh = session.requests.contains {
                    $0.url?.path == "/podcasts/completed-id/completed"
                }
            }
        )
        await vm.addToQueue(queuePodcast("completed-id"))
        await vm.addToQueue(queuePodcast("next-id"))

        await vm.handlePlaybackEnded()

        // WHY: handlePlaybackEnded の順序入れ替え（UI収束を先行させる）により、
        //      stopPlayback() 由来の /position 同期 Task が /completed より先に
        //      enqueue され得るため、リクエスト**順序**ではなく含有で検証する。
        let completedRequest = try XCTUnwrap(
            session.requests.first { $0.url?.path == "/podcasts/completed-id/completed" }
        )
        XCTAssertEqual(completedRequest.httpMethod, "POST")
        XCTAssertNil(completedRequest.httpBody)
        XCTAssertEqual(vm.currentPodcast?.id, "next-id")
        XCTAssertEqual(refreshCount, 1)
        // 順序非依存: ストリーク更新は完聴記録の後、という契約のみを検証する。
        XCTAssertTrue(completedSentBeforeRefresh)
    }

    func testCompletionFailureDoesNotBlockQueueAutoAdvance() async {
        let session = RequestRecordingSession(statusCode: 500)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        let vm = makeViewModel(
            apiClient: client,
            networkMonitor: StubNetworkMonitor(isOnline: true)
        )
        await vm.addToQueue(queuePodcast("failed-completion"))
        await vm.addToQueue(queuePodcast("still-plays"))

        await vm.handlePlaybackEnded()

        // 順序非依存: /completed リクエストが送られたことのみを検証する（§理由は上記テスト参照）。
        XCTAssertTrue(session.requests.contains { $0.url?.path == "/podcasts/failed-completion/completed" })
        XCTAssertEqual(vm.currentPodcast?.id, "still-plays")
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

    // MARK: - issue #59: KVO コールバックの stale 実行対策

    func testShouldProcessPlayerItemCallbackTrueWhenMatchesCurrentItem() async throws {
        let vm = await playingViewModel()
        let currentItem = try XCTUnwrap(vm.player?.currentItem)

        XCTAssertTrue(vm.shouldProcessPlayerItemCallback(currentItem))
    }

    func testShouldProcessPlayerItemCallbackFalseForDifferentItem() async throws {
        let vm = await playingViewModel()
        let staleItem = AVPlayerItem(url: URL(string: "https://storage.example.com/stale.mp3")!)

        XCTAssertFalse(vm.shouldProcessPlayerItemCallback(staleItem))
    }

    func testShouldProcessPlayerItemCallbackFalseWhenPlayerNil() {
        let vm = makeOnlineViewModel()
        let item = AVPlayerItem(url: URL(string: "https://storage.example.com/none.mp3")!)

        XCTAssertFalse(vm.shouldProcessPlayerItemCallback(item))
    }

    func testShouldProcessPlayerCallbackTrueWhenMatchesCurrentPlayer() async throws {
        let vm = await playingViewModel()
        let currentPlayer = try XCTUnwrap(vm.player)

        XCTAssertTrue(vm.shouldProcessPlayerCallback(currentPlayer))
    }

    func testShouldProcessPlayerCallbackFalseForDifferentPlayer() async throws {
        let vm = await playingViewModel()
        let stalePlayer = AVPlayer()

        XCTAssertFalse(vm.shouldProcessPlayerCallback(stalePlayer))
    }

    func testShouldProcessPlayerCallbackFalseWhenPlayerNil() {
        let vm = makeOnlineViewModel()
        let player = AVPlayer()

        XCTAssertFalse(vm.shouldProcessPlayerCallback(player))
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

    // MARK: - 完了時自動収束

    func testQueueEndSetsFinishedState() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))   // キューは [a] のみ

        await vm.handlePlaybackEnded()

        XCTAssertTrue(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentPodcast?.id, "a")
        XCTAssertFalse(vm.isPlaying)
    }

    func testAutoAdvanceDoesNotSetFinishedState() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        await vm.addToQueue(queuePodcast("b"))

        await vm.handlePlaybackEnded()           // a 終了 → 自動で b へ

        XCTAssertFalse(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentPodcast?.id, "b")
    }

    func testReplayCurrentEpisodeClearsFinishedStateAndPlaysFromZero() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        await vm.handlePlaybackEnded()
        XCTAssertTrue(vm.didFinishCurrentEpisode)

        await vm.replayCurrentEpisode()

        XCTAssertFalse(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentPodcast?.id, "a")
        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(vm.currentTime, 0)
    }

    func testReplayCurrentEpisodeOverridesMidPositionRestore() async {
        // WHY: finished 状態への復帰時に、サーバーから復元された途中位置（playbackPositionSeconds: 120）
        //      を replayCurrentEpisode() が seek(to: 0) で明示的に上書きすることを検証。
        //      修正対象: replayCurrentEpisode() 内の seek(to: 0) を削ると、このテストは RED になる。
        let vm = makeOnlineViewModel()
        let podcast = queuePodcast("mid-position", playbackPositionSeconds: 120, durationSeconds: 300)
        vm.currentPodcast = podcast
        await vm.handlePlaybackEnded()
        XCTAssertTrue(vm.didFinishCurrentEpisode)

        await vm.replayCurrentEpisode()

        XCTAssertFalse(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentTime, 0)  // 途中位置 120s を上書き
    }

    func testReplayCurrentEpisodeIsNoOpWithoutCurrentPodcast() async {
        let vm = makeOnlineViewModel()

        await vm.replayCurrentEpisode()

        XCTAssertNil(vm.currentPodcast)
        XCTAssertFalse(vm.isPlaying)
    }

    func testReplayWhileOfflineNotCachedKeepsFinishedStateAndSetsError() async {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(data: Data("{}".utf8), statusCode: 200)
        )
        let vm = makeViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: false))
        let podcast = queuePodcast("offline-episode")
        vm.currentPodcast = podcast
        await vm.handlePlaybackEnded()           // キュー空 → 収束
        XCTAssertTrue(vm.didFinishCurrentEpisode)

        await vm.replayCurrentEpisode()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.didFinishCurrentEpisode)
    }

    func testStopPlaybackDoesNotSetFinishedState() async throws {
        let vm = await playingViewModel()

        vm.stopPlayback()

        XCTAssertFalse(vm.didFinishCurrentEpisode)
    }

    func testStopPlaybackAfterFinishPreservesFinishedState() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        await vm.handlePlaybackEnded()
        XCTAssertTrue(vm.didFinishCurrentEpisode)

        vm.stopPlayback()                        // タブ離脱を想定

        XCTAssertTrue(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentPodcast?.id, "a")
    }

    func testPlayDifferentEpisodeClearsFinishedState() async {
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        await vm.handlePlaybackEnded()
        XCTAssertTrue(vm.didFinishCurrentEpisode)

        await vm.play(podcast: queuePodcast("b"))

        XCTAssertFalse(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentPodcast?.id, "b")
    }

    func testPlayWithEndPositionStartsFromZero() async {
        // 保存位置が末尾±2秒 → 完聴済みの記録とみなし、復元せず先頭から再生する
        // （再タップ即完了ループの回帰防止）。
        let vm = makeOnlineViewModel()
        let podcast = queuePodcast("resumed", playbackPositionSeconds: 58, durationSeconds: 60)

        await vm.play(podcast: podcast)

        XCTAssertEqual(vm.currentTime, 0)
    }

    func testPlayWithMidPositionRestoresPosition() async {
        // 対のテスト: 末尾ガードが途中位置の復元まで巻き込んで殺していないことを確認する。
        let vm = makeOnlineViewModel()
        let podcast = queuePodcast("mid", playbackPositionSeconds: 120, durationSeconds: 300)

        await vm.play(podcast: podcast)

        XCTAssertEqual(vm.currentTime, 120)
    }

    func testPlayWithZeroDurationRestoresPosition() async {
        // durationSeconds == 0（メタデータ欠損）で isAtEnd が常に true にならず、
        // レジューム自体が無効化されない境界を確認する。
        let vm = makeOnlineViewModel()
        let podcast = queuePodcast("zero-duration", playbackPositionSeconds: 30, durationSeconds: 0)

        await vm.play(podcast: podcast)

        XCTAssertEqual(vm.currentTime, 30)
    }

    func testEndOfPlaybackObserverCapturesEndedIdAtRegistrationNotAtFireTime() async throws {
        // PR #74 レビュー指摘: 終了通知(didPlayToEndTimeNotification)は queue: .main 経由で
        // 非同期配信されるため、クロージャ発火時点で self.currentPodcast を読むと、
        // 登録〜発火の間に利用者が別エピソードへ切り替えた場合、新しい currentPodcast の ID を
        // 「終了した episode の ID」として誤って渡してしまい、handlePlaybackEnded 側の
        // stale ガード（currentPodcast?.id != endedId）が素通りする。
        // ここでは stopPlayback() を経由させず currentPodcast だけを書き換えることで、
        // 「観測オブザーバは a の item を指したまま、currentPodcast だけ b に変わった」状況を再現する。
        let session = RequestRecordingSession()
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        let vm = makeViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: true))
        await vm.play(podcast: queuePodcast("a"))
        let endedItem = try XCTUnwrap(vm.player?.currentItem)

        vm.currentPodcast = queuePodcast("b")

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: endedItem)
        try await Task.sleep(nanoseconds: 300_000_000)

        // a の stale な終了通知が b に誤適用されていないこと。
        XCTAssertEqual(vm.currentPodcast?.id, "b")
        XCTAssertFalse(vm.didFinishCurrentEpisode)
        XCTAssertFalse(session.requests.contains { $0.url?.path == "/podcasts/b/completed" })
    }

    func testEndOfPlaybackObserverTriggersConvergenceForCurrentEpisode() async throws {
        // 上の stale テストの正方向対照（positive control）。これが無いと、オブザーバが
        // handlePlaybackEnded を一切呼ばないミュータントでも stale テストは green のまま通り、
        // 「ガードが効いている」ことと「オブザーバが死んでいる」ことを区別できない
        // （敵対的検証のミューテーションテストで実証済み）。
        // 実 NotificationCenter 配信経路で、現エピソードの終了通知が収束と完聴記録を起こすことを固定する。
        let session = RequestRecordingSession()
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        let vm = makeViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: true))
        await vm.addToQueue(queuePodcast("a"))
        let endedItem = try XCTUnwrap(vm.player?.currentItem)

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: endedItem)
        try await Task.sleep(nanoseconds: 300_000_000)

        // キュー終端: 収束フラグが立ち、a の完聴が記録される。
        XCTAssertTrue(vm.didFinishCurrentEpisode)
        XCTAssertEqual(vm.currentPodcast?.id, "a")
        XCTAssertTrue(session.requests.contains { $0.url?.path == "/podcasts/a/completed" })
    }

    func testHandlePlaybackEndedIgnoresStaleEndedId() async {
        // 終了通知の endedId が、その間に利用者が切り替えた現在の episode と一致しなければ
        // 収束もキュー遷移も起こさない（issue #59 の shouldProcessPlayerItemCallback と同型のガード）。
        let vm = makeOnlineViewModel()
        await vm.addToQueue(queuePodcast("a"))
        await vm.addToQueue(queuePodcast("b"))
        await vm.play(podcast: queuePodcast("b"))

        await vm.handlePlaybackEnded(endedId: "a")

        XCTAssertEqual(vm.currentPodcast?.id, "b")
        XCTAssertFalse(vm.didFinishCurrentEpisode)
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
