import XCTest
@testable import NewsListenApp

// PodcastViewModel は @MainActor 分離（AVPlayer 操作を含む）のため、
// テストクラスも @MainActor にして init / メソッド呼び出しの分離コンテキストを揃える。
@MainActor
final class PodcastViewModelTests: XCTestCase {

    func testLoadPodcastsPopulatesList() async throws {
        let mockJSON = #"""
        {"podcasts": [
            {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z"}
        ]}
        """#.data(using: .utf8)!

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )
        let vm = PodcastViewModel(apiClient: client)

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
        let vm = PodcastViewModel(apiClient: client)

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
        let vm = PodcastViewModel(apiClient: client)

        vm.setSpeed(1.5)

        XCTAssertEqual(vm.playbackSpeed, 1.5)
    }
}
