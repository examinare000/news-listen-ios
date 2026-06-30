import XCTest
@testable import NewsListenApp

/// APIClient のセッション管理 3 エンドポイント（issue #84）のテスト。
/// MockURLSession は APIClientTests.swift で定義済み（テストターゲット全体で共有）。
@MainActor
final class SessionsAPIClientTests: XCTestCase {

    private func makeClient(data: Data, status: Int = 200, token: String? = "bearer-tok") -> (APIClient, MockURLSession) {
        let session = MockURLSession(data: data, statusCode: status)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "api-key",
            sessionToken: token,
            session: session
        )
        return (client, session)
    }

    func testListSessionsGetsAndDecodes() async throws {
        let json = """
        {"sessions":[
          {"id":"sid-current","device_label":"Chrome on macOS","created_at":"2026-06-01T00:00:00Z","last_used_at":"2026-06-30T12:00:00Z","current":true},
          {"id":"sid-other","device_label":"Safari on iOS","created_at":"2026-05-01T00:00:00Z","last_used_at":null,"current":false}
        ]}
        """
        let (client, session) = makeClient(data: Data(json.utf8))

        let resp = try await client.listSessions()

        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/sessions")
        XCTAssertEqual(session.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(resp.sessions.count, 2)
        XCTAssertEqual(resp.sessions[0].sessionID, "sid-current")
        XCTAssertTrue(resp.sessions[0].current)
        XCTAssertEqual(resp.sessions[0].deviceLabel, "Chrome on macOS")
        XCTAssertNil(resp.sessions[1].lastUsedAt)
    }

    func testRevokeSessionDeletesAtPath() async throws {
        let (client, session) = makeClient(data: Data("{\"status\":\"ok\"}".utf8))

        try await client.revokeSession(id: "sid-other")

        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/sessions/sid-other")
        XCTAssertEqual(session.lastRequest?.httpMethod, "DELETE")
    }

    func testRevokeSessionMaps404ToHttpError() async {
        let (client, _) = makeClient(data: Data(), status: 404)

        do {
            try await client.revokeSession(id: "nope")
            XCTFail("404 should throw")
        } catch APIError.httpError(let code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRevokeOtherSessionsPostsAndDecodes() async throws {
        let (client, session) = makeClient(data: Data("{\"revoked_count\":3}".utf8))

        let resp = try await client.revokeOtherSessions()

        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/sessions/revoke-others")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(resp.revokedCount, 3)
    }
}
