import XCTest
@testable import NewsListenApp

/// APIClient の認証・ユーザー管理エンドポイントのテスト。
@MainActor
final class AuthAPIClientTests: XCTestCase {

    private func makeClient(data: Data, status: Int = 200, token: String? = nil) -> (APIClient, MockURLSession) {
        let session = MockURLSession(data: data, statusCode: status)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "api-key",
            sessionToken: token,
            session: session
        )
        return (client, session)
    }

    func testLoginPostsCredentialsAndDecodes() async throws {
        let json = #"{"token":"tok-123","user":{"username":"alice","role":"user","display_name":"Alice"}}"#.data(using: .utf8)!
        let (client, session) = makeClient(data: json)

        let res = try await client.login(username: "alice", password: "pw")

        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/login")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
        // 最もセキュリティ上重要な「正しい資格情報が JSON ボディで送られる」ことを検証する。
        let body = try XCTUnwrap(session.lastRequest?.httpBody)
        let bodyJSON = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(bodyJSON?["username"] as? String, "alice")
        XCTAssertEqual(bodyJSON?["password"] as? String, "pw")
        XCTAssertEqual(res.token, "tok-123")
        XCTAssertEqual(res.user.username, "alice")
        XCTAssertEqual(res.user.displayName, "Alice")
    }

    func testSessionTokenSetsBearerHeader() async throws {
        let json = #"{"username":"alice","role":"admin","display_name":"Alice"}"#.data(using: .utf8)!
        let (client, session) = makeClient(data: json, token: "tok-xyz")

        let me = try await client.fetchMe()

        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/me")
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-xyz")
        XCTAssertTrue(me.isAdmin)
    }

    func testNoBearerHeaderWhenTokenAbsent() async throws {
        let json = #"{"token":"t","user":{"username":"a","role":"user","display_name":"A"}}"#.data(using: .utf8)!
        let (client, session) = makeClient(data: json, token: nil)

        _ = try await client.login(username: "a", password: "b")

        XCTAssertNil(session.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        // ゲートウェイの X-API-Key は常に付与される。
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "X-API-Key"), "api-key")
    }

    func testLogin401ThrowsHTTPError() async throws {
        let (client, _) = makeClient(data: Data(), status: 401)
        do {
            _ = try await client.login(username: "x", password: "y")
            XCTFail("401 で APIError が送出されるべき")
        } catch let APIError.httpError(code) {
            XCTAssertEqual(code, 401)
        }
    }

    func testUpdateProfileUsesPatch() async throws {
        let json = #"{"username":"alice","role":"user","display_name":"New"}"#.data(using: .utf8)!
        let (client, session) = makeClient(data: json, token: "t")

        let updated = try await client.updateProfile(displayName: "New")

        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/me")
        XCTAssertEqual(session.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(updated.displayName, "New")
    }

    func testListUsersDecodes() async throws {
        let json = #"{"users":[{"username":"a","role":"admin","display_name":"A"},{"username":"b","role":"user","display_name":"B"}]}"#.data(using: .utf8)!
        let (client, session) = makeClient(data: json, token: "t")

        let res = try await client.listUsers()

        XCTAssertEqual(session.lastRequest?.url?.path, "/admin/users")
        XCTAssertEqual(res.users.count, 2)
        XCTAssertEqual(res.users[0].username, "a")
    }

    func testUpdateUserUsesPatchOnUsernamePath() async throws {
        let json = #"{"username":"bob","role":"admin","display_name":"Bob"}"#.data(using: .utf8)!
        let (client, session) = makeClient(data: json, token: "t")

        _ = try await client.updateUser(username: "bob", role: "admin")

        XCTAssertEqual(session.lastRequest?.url?.path, "/admin/users/bob")
        XCTAssertEqual(session.lastRequest?.httpMethod, "PATCH")
        // 指定したフィールドのみがボディに含まれること（role だけ送る）。
        let body = try XCTUnwrap(session.lastRequest?.httpBody)
        let bodyJSON = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(bodyJSON?["role"] as? String, "admin")
        XCTAssertNil(bodyJSON?["new_password"])
    }

    func testDeleteUserUsesDeleteOnUsernamePath() async throws {
        let (client, session) = makeClient(data: Data(), token: "t")

        try await client.deleteUser(username: "bob")

        XCTAssertEqual(session.lastRequest?.url?.path, "/admin/users/bob")
        XCTAssertEqual(session.lastRequest?.httpMethod, "DELETE")
    }
}
