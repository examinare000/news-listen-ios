import XCTest
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
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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

    // MARK: - リモートコマンド経路と同じ再生制御メソッドの状態遷移（issue #79）

    private func playingViewModel() async -> PodcastViewModel {
        let podcast = Podcast(
            id: "p1", type: "single", articleIds: ["a1"], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/p1.mp3", japaneseIntroText: "test",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed", errorMessage: nil,
            playbackPositionSeconds: 0.0
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
