import XCTest
@testable import NewsListenApp

/// APIClient の passkey 6 エンドポイントのテスト。
/// MockURLSession は APIClientTests.swift で定義済み（テストターゲット全体で共有）。
@MainActor
final class PasskeyAPIClientTests: XCTestCase {

    // MARK: Helpers

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

    private func optionsResponseData(challengeID: String = "chal-1") -> Data {
        let inner = #"{"rpId":"rp.example.com","challenge":"Y2hhbGxlbmdl","allowCredentials":[],"timeout":60000,"userVerification":"required"}"#
        let outer: [String: Any] = ["challenge_id": challengeID, "options": inner]
        return try! JSONSerialization.data(withJSONObject: outer)
    }

    // MARK: register/options

    func testRegisterOptionsPostsToCorrectPath() async throws {
        let (client, session) = makeClient(data: optionsResponseData())
        _ = try await client.passkeyRegisterOptions()
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/passkey/register/options")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
    }

    func testRegisterOptionsSendsBearerToken() async throws {
        let (client, session) = makeClient(data: optionsResponseData(), token: "tok-xyz")
        _ = try await client.passkeyRegisterOptions()
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-xyz")
    }

    func testRegisterOptionsDecodesResponse() async throws {
        let (client, _) = makeClient(data: optionsResponseData(challengeID: "chal-reg-1"))
        let resp = try await client.passkeyRegisterOptions()
        XCTAssertEqual(resp.challengeID, "chal-reg-1")
        XCTAssertTrue(resp.options.contains("rpId"))
    }

    // MARK: register/verify

    func testRegisterVerifyPostsToCorrectPath() async throws {
        let (client, session) = makeClient(data: #"{"status":"ok"}"#.data(using: .utf8)!)
        try await client.passkeyRegisterVerify(
            challengeID: "chal-1",
            credential: ["id": "cred-id", "type": "public-key"]
        )
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/passkey/register/verify")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
    }

    func testRegisterVerifyBodyContainsChallengeIDAndCredential() async throws {
        let (client, session) = makeClient(data: #"{"status":"ok"}"#.data(using: .utf8)!)
        let credDict: [String: Any] = ["id": "abc", "type": "public-key"]
        try await client.passkeyRegisterVerify(challengeID: "chal-xyz", credential: credDict)

        let body = try XCTUnwrap(session.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["challenge_id"] as? String, "chal-xyz")
        let nestedCred = try XCTUnwrap(json["credential"] as? [String: Any])
        XCTAssertEqual(nestedCred["id"] as? String, "abc")
    }

    // MARK: login/options

    func testLoginOptionsPostsToCorrectPathWithEmptyBody() async throws {
        let (client, session) = makeClient(data: optionsResponseData())
        _ = try await client.passkeyLoginOptions()
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/passkey/login/options")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
        // 空 dict {} を送ること（nil ではなくボディあり）。
        let body = try XCTUnwrap(session.lastRequest?.httpBody, "login/options は {} ボディを送ること")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(bodyJSON.count, 0, "body は空 dict であること")
    }

    func testLoginOptionsDecodesResponse() async throws {
        let (client, _) = makeClient(data: optionsResponseData(challengeID: "chal-login-1"))
        let resp = try await client.passkeyLoginOptions()
        XCTAssertEqual(resp.challengeID, "chal-login-1")
    }

    // MARK: login/verify

    func testLoginVerifyPostsToCorrectPath() async throws {
        let loginJSON = #"{"token":"tok","user":{"username":"alice","role":"user","display_name":"Alice"}}"#
        let (client, session) = makeClient(data: loginJSON.data(using: .utf8)!)
        _ = try await client.passkeyLoginVerify(
            challengeID: "chal-1",
            credential: ["id": "cred-id", "type": "public-key"]
        )
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/passkey/login/verify")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
    }

    func testLoginVerifyBodyContainsChallengeIDAndCredential() async throws {
        let loginJSON = #"{"token":"tok","user":{"username":"alice","role":"user","display_name":"Alice"}}"#
        let (client, session) = makeClient(data: loginJSON.data(using: .utf8)!)
        let credDict: [String: Any] = ["id": "cred-id", "rawId": "cred-id", "type": "public-key"]
        _ = try await client.passkeyLoginVerify(challengeID: "chal-abc", credential: credDict)

        let body = try XCTUnwrap(session.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["challenge_id"] as? String, "chal-abc")
        let nestedCred = try XCTUnwrap(json["credential"] as? [String: Any])
        XCTAssertEqual(nestedCred["id"] as? String, "cred-id")
    }

    func testLoginVerifyDecodesLoginResponse() async throws {
        let loginJSON = #"{"token":"tok-passkey","user":{"username":"alice","role":"user","display_name":"Alice"}}"#
        let (client, _) = makeClient(data: loginJSON.data(using: .utf8)!)
        let resp = try await client.passkeyLoginVerify(
            challengeID: "chal-1",
            credential: ["id": "c"]
        )
        XCTAssertEqual(resp.token, "tok-passkey")
        XCTAssertEqual(resp.user.username, "alice")
    }

    // MARK: list credentials

    func testListCredentialsGetsToCorrectPath() async throws {
        let json = #"{"credentials":[]}"#
        let (client, session) = makeClient(data: json.data(using: .utf8)!)
        _ = try await client.listPasskeyCredentials()
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/passkey/credentials")
        XCTAssertEqual(session.lastRequest?.httpMethod, "GET")
    }

    func testListCredentialsSendsBearerToken() async throws {
        let json = #"{"credentials":[]}"#
        let (client, session) = makeClient(data: json.data(using: .utf8)!, token: "tok-list")
        _ = try await client.listPasskeyCredentials()
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-list")
    }

    func testListCredentialsDecodesResponse() async throws {
        let json = """
        {"credentials":[
            {"credential_id":"cred-abc","username":"alice","name":null,"transports":["internal"],
             "aaguid":null,"sign_count":3,"created_at":"2026-01-01T00:00:00Z","last_used_at":null}
        ]}
        """
        let (client, _) = makeClient(data: json.data(using: .utf8)!)
        let resp = try await client.listPasskeyCredentials()
        XCTAssertEqual(resp.credentials.count, 1)
        XCTAssertEqual(resp.credentials[0].credentialID, "cred-abc")
    }

    // MARK: delete credential

    func testDeleteCredentialDeletesToCorrectPath() async throws {
        let (client, session) = makeClient(data: #"{"status":"ok"}"#.data(using: .utf8)!)
        try await client.deletePasskeyCredential(id: "cred-abc-123")
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/passkey/credentials/cred-abc-123")
        XCTAssertEqual(session.lastRequest?.httpMethod, "DELETE")
    }

    func testDeleteCredentialSendsBearerToken() async throws {
        let (client, session) = makeClient(data: Data(), token: "tok-del")
        try await client.deletePasskeyCredential(id: "cred-xyz")
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-del")
    }

    func testDeleteCredentialHTTPErrorThrows() async throws {
        let (client, _) = makeClient(data: Data(), status: 404)
        do {
            try await client.deletePasskeyCredential(id: "cred-xyz")
            XCTFail("404 でエラーが投げられるべき")
        } catch let APIError.httpError(code) {
            XCTAssertEqual(code, 404)
        }
    }
}
