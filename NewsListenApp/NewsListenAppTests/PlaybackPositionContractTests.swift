import XCTest
@testable import NewsListenApp

/// 位置の送信（`PATCH /podcasts/{id}/position`）の request と、応答の `playback_position_recorded_at` の decode。
/// `MockURLSession` で実際の method・path・body を固定する（backend の契約との一致）。
@MainActor
final class PlaybackPositionContractTests: XCTestCase {

    private let baseURL = URL(string: "https://api.example.com")!

    private func podcastJSON(id: String = "p1", recordedAt: String? = nil, includeKey: Bool = true) -> Data {
        let recorded = includeKey ? #","playback_position_recorded_at":\#(recordedAt.map { "\"\($0)\"" } ?? "null")"# : ""
        return Data(#"""
        {"id":"\#(id)","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/\#(id).mp3","title":"題","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed","playback_position_seconds":42.0\#(recorded)}
        """#.utf8)
    }

    private func client(_ session: MockURLSession) -> APIClient {
        APIClient(baseURL: baseURL, apiKey: "key", session: session)
    }

    private func body(of session: MockURLSession) throws -> [String: Any] {
        let data = try XCTUnwrap(session.lastRequest?.httpBody, "body が無い")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 2026-11-16T10:00:00Z。期待値は書式の自前実装に頼らず、標準の parser で作る。
    private var base: Date { ISO8601DateFormatter().date(from: "2026-11-16T10:00:00Z")! }

    private func serverRecordedAt(of podcast: Podcast) -> Date? {
        guard case .playable(let playable) = podcast.toEpisode() else { return nil }
        return playable.serverRecordedAt
    }

    // verifies: ios-contract-13（backend の PATCH body。recorded_at は UTC・小数 3 桁・末尾 Z）
    // kills: recorded_at を送らない／ミリ秒より細かい端数を送る／UTC でない書式を送る
    func testPatchBodyHasPositionSecondsAndRecordedAtAsUTCISO8601WithMilliseconds() async throws {
        // 小数部は 2 進で厳密に表せる値と、3 桁を超える端数を持つ値で確かめる（切り捨て）。
        for (fraction, expected) in [(0.125, "2026-11-16T10:00:00.125Z"), (0.1255, "2026-11-16T10:00:00.125Z")] {
            let session = MockURLSession(data: podcastJSON(), statusCode: 200)

            _ = try await client(session).updatePlaybackPosition(
                podcastId: "p1", positionSeconds: 45.5, recordedAt: base.addingTimeInterval(fraction))

            XCTAssertEqual(session.lastRequest?.httpMethod, "PATCH")
            XCTAssertEqual(session.lastRequest?.url?.path, "/podcasts/p1/position")
            let json = try body(of: session)
            XCTAssertEqual(Set(json.keys), ["position_seconds", "recorded_at"])
            XCTAssertEqual(json["position_seconds"] as? Double, 45.5)
            XCTAssertEqual(json["recorded_at"] as? String, expected)
        }
    }

    // verifies: ios-contract-13（旧クライアント互換。recordedAt が nil なら recorded_at を送らない）
    // kills: nil のとき null や現在時刻を入れる
    func testPatchBodyWithoutRecordedAtKeepsTheLegacyShape() async throws {
        let session = MockURLSession(data: podcastJSON(), statusCode: 200)

        _ = try await client(session).updatePlaybackPosition(podcastId: "p1", positionSeconds: 45.5, recordedAt: nil)

        let json = try body(of: session)
        XCTAssertEqual(Set(json.keys), ["position_seconds"])
    }

    // verifies: ios-contract-13（応答の記録時刻を Z・オフセット・小数 0〜9 桁で読み、読めなければ nil）
    // kills: ISO8601DateFormatter の小数の扱いに依存する／オフセットを UTC へ直さない／欠落・null で decode を失敗させる
    func testResponseRecordedAtDecodesZOffsetMicrosecondsNullAndMissing() async throws {
        let cases: [(label: String, json: Data, expected: Date?)] = [
            ("Z", podcastJSON(recordedAt: "2026-11-16T10:00:00Z"), base),
            ("+00:00", podcastJSON(recordedAt: "2026-11-16T10:00:00+00:00"), base),
            ("マイクロ秒", podcastJSON(recordedAt: "2026-11-16T10:00:00.123456Z"), base.addingTimeInterval(0.123)),
            ("+09:00", podcastJSON(recordedAt: "2026-11-16T19:00:00+09:00"), base),
            ("null", podcastJSON(recordedAt: nil), nil),
            ("欠落", podcastJSON(includeKey: false), nil),
        ]
        for testCase in cases {
            let session = MockURLSession(data: testCase.json, statusCode: 200)
            let podcast = try await client(session).fetchPodcast(id: "p1")
            let actual = serverRecordedAt(of: podcast)
            switch (actual, testCase.expected) {
            case let (actual?, expected?):
                XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0005, testCase.label)
            case (nil, nil):
                break
            default:
                XCTFail("\(testCase.label): \(String(describing: actual)) ≠ \(String(describing: testCase.expected))")
            }
        }
    }

    // verifies: ios-contract-13（一覧・詳細の応答の記録時刻が PlayableEpisode まで届く）
    // kills: 一覧か詳細のどちらかで時刻を落とす
    func testListAndDetailResponseRecordedAtReachPlayableEpisode() async throws {
        let detail = try await client(MockURLSession(
            data: podcastJSON(recordedAt: "2026-11-16T10:00:00Z"), statusCode: 200)).fetchPodcast(id: "p1")
        XCTAssertEqual(serverRecordedAt(of: detail), base)

        let item = String(decoding: podcastJSON(id: "p2", recordedAt: "2026-11-16T10:00:00Z"), as: UTF8.self)
        let list = try await client(MockURLSession(
            data: Data(#"{"podcasts":[\#(item)]}"#.utf8), statusCode: 200)).fetchPodcasts()
        XCTAssertEqual(list.podcasts.first.flatMap(serverRecordedAt(of:)), base)
    }

    // verifies: ios-contract-13（404・422 は notFound 等へ写さず unknown(status:) のまま）
    // kills: 404 を別の failure に分類する／422 を validation にする
    func testPatch404And422AreUnknownStatusNotNotFound() async throws {
        for status in [404, 422] {
            let session = MockURLSession(data: Data(), statusCode: status)
            do {
                _ = try await client(session).updatePlaybackPosition(
                    podcastId: "p1", positionSeconds: 1, recordedAt: base)
                XCTFail("\(status) で throw するべき")
            } catch let failure as ApiFailure {
                XCTAssertEqual(failure, .unknown(status: status))
            }
        }
    }

    // verifies: ios-contract-13（PlaybackGateway.live が記録時刻をそのまま client へ渡す）
    // kills: gateway が時刻を捨てる／別の時刻（現在時刻）を付ける
    func testPlaybackGatewayPassesRecordedAtToTheClient() async throws {
        let session = MockURLSession(data: podcastJSON(), statusCode: 200)
        let gateway = PlaybackGateway.live(apiClient: client(session))

        let episode = try await gateway.updatePosition("p1", 42, base.addingTimeInterval(0.125))

        XCTAssertEqual(try body(of: session)["recorded_at"] as? String, "2026-11-16T10:00:00.125Z")
        XCTAssertEqual(try body(of: session)["position_seconds"] as? Double, 42)
        guard case .playable = episode else { return XCTFail("応答は Episode に変換される") }
    }
}
