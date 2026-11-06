import XCTest
@testable import NewsListenApp

/// `AccountGateway.live(client:)`（adapter）のテスト。client を呼出ごとに解決すること、nil の client の扱い、
/// 応答の変換と要求の宛先・本文を固定する。
@MainActor
final class AccountGatewayLiveTests: XCTestCase {

    private let baseURL = URL(string: "https://api.example.com")!

    private func makeClient(session: URLSessionProtocol, token: String = "tok") -> APIClient {
        APIClient(baseURL: baseURL, apiKey: "key", sessionToken: token, session: session)
    }

    private func body(_ session: MockURLSession) throws -> [String: Any] {
        let data = try XCTUnwrap(session.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let loginJSON = #"{"token":"tok-login","user":{"username":"alice","role":"admin","display_name":"Alice","user_id":"u_alice-1"}}"#
    private let userJSON = #"{"username":"bob","role":"admin","display_name":"Bob","user_id":"u_bob"}"#

    private var registrationOptionsResponse: Data {
        let inner: [String: Any] = [
            "rp": ["id": "rp.example.com", "name": "News Listen"],
            "user": ["id": "dXNlcklE", "name": "alice", "displayName": "Alice"],
            "challenge": "Y2hhbGxlbmdl",
            "pubKeyCredParams": [["type": "public-key", "alg": -7]],
            "timeout": 60000,
            "excludeCredentials": [],
            "attestation": "none",
        ]
        let innerString = String(data: try! JSONSerialization.data(withJSONObject: inner), encoding: .utf8)!
        return try! JSONSerialization.data(withJSONObject: ["challenge_id": "chal-reg-9", "options": innerString])
    }

    private var assertionOptionsResponse: Data {
        let innerString = #"{"rpId":"rp-login.example.com","challenge":"Y2hhbGxlbmdl","allowCredentials":[],"timeout":60000,"userVerification":"required"}"#
        return try! JSONSerialization.data(withJSONObject: ["challenge_id": "chal-login-9", "options": innerString])
    }

    // MARK: - nil の client

    // verifies: ios-dec-107
    func testIosDec107_everyClosureThrowsBadURLNetworkFailureWhenClientIsNil() async {
        let gateway = AccountGateway.live(client: { nil })
        let registrationCredential = MockPasskeyProvider.makeRegistrationCredential()
        let assertionCredential = MockPasskeyProvider.makeAssertionCredential()
        let operations: [(String, () async throws -> Void)] = [
            ("updateProfile", { _ = try await gateway.updateProfile("x") }),
            ("changePassword", { try await gateway.changePassword("a", "b") }),
            ("login", { _ = try await gateway.login("a", "b") }),
            ("listSessions", { _ = try await gateway.listSessions() }),
            ("revokeSession", { try await gateway.revokeSession("s1") }),
            ("revokeOtherSessions", { _ = try await gateway.revokeOtherSessions() }),
            ("passkeyRegisterOptions", { _ = try await gateway.passkeyRegisterOptions() }),
            ("passkeyRegisterVerify", { try await gateway.passkeyRegisterVerify("c", registrationCredential) }),
            ("passkeyLoginOptions", { _ = try await gateway.passkeyLoginOptions() }),
            ("passkeyLoginVerify", { _ = try await gateway.passkeyLoginVerify("c", assertionCredential) }),
            ("listPasskeyCredentials", { _ = try await gateway.listPasskeyCredentials() }),
            ("deletePasskeyCredential", { try await gateway.deletePasskeyCredential("c1") }),
            ("listUsers", { _ = try await gateway.listUsers() }),
            ("createUser", { try await gateway.createUser("bob", "p", nil, .user) }),
            ("updateUserRole", { try await gateway.updateUserRole("bob", .admin) }),
            ("deleteUser", { try await gateway.deleteUser("bob") }),
        ]
        XCTAssertEqual(operations.count, 16)

        for (name, operation) in operations {
            do {
                try await operation()
                XCTFail("\(name) は nil の client で失敗する")
            } catch {
                XCTAssertEqual(error as? ApiFailure, .network(URLError(.badURL)), name)
            }
        }
    }

    // MARK: - 呼出ごとの解決

    // verifies: ios-dec-107
    func testIosDec107_clientIsResolvedOnEveryCall() async throws {
        let sessionA = ScriptedURLSession()
        let sessionB = ScriptedURLSession()
        sessionA.configure(method: "GET", path: "/auth/sessions", status: 200, body: Data(#"{"sessions":[]}"#.utf8))
        sessionB.configure(method: "GET", path: "/auth/sessions", status: 200, body: Data(#"{"sessions":[]}"#.utf8))
        let clients = [makeClient(session: sessionA, token: "tA"), makeClient(session: sessionB, token: "tB")]
        var resolveCount = 0
        let gateway = AccountGateway.live(client: {
            defer { resolveCount += 1 }
            return clients[min(resolveCount, clients.count - 1)]
        })

        _ = try await gateway.listSessions()
        _ = try await gateway.listSessions()

        XCTAssertEqual(sessionA.sentRequests.count, 1, "1 回目は clientA の session")
        XCTAssertEqual(sessionB.sentRequests.count, 1, "2 回目は clientB の session")
        XCTAssertEqual(sessionA.sentRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tA")
        XCTAssertEqual(sessionB.sentRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tB")
    }

    // MARK: - 応答の変換

    // verifies: ios-dec-107, ios-cmd-account-01
    func testIosDec107_responsesAreMappedFieldByField() async throws {
        let sessionsJSON = #"{"sessions":[{"id":"sid-1","device_label":"iPhone 15","created_at":"2026-01-01T00:00:00Z","last_used_at":"2026-01-02T00:00:00Z","current":true},{"id":"sid-2","device_label":null,"created_at":"2026-02-01T00:00:00Z","last_used_at":null,"current":false}]}"#
        let credentialsJSON = #"{"credentials":[{"credential_id":"cred-1","username":"alice","name":"My Key","transports":["internal"],"sign_count":7,"created_at":"2026-03-01T00:00:00Z"}]}"#
        let usersJSON = #"{"users":[{"username":"bob","role":"x","display_name":"Bob","user_id":"u_bob"}]}"#

        let sessions = try await AccountGateway.live(client: { self.makeClient(session: MockURLSession(data: Data(sessionsJSON.utf8), statusCode: 200)) }).listSessions()
        let receipt = try await AccountGateway.live(client: { self.makeClient(session: MockURLSession(data: Data(self.loginJSON.utf8), statusCode: 200)) }).login("alice", "pw")
        let credentials = try await AccountGateway.live(client: { self.makeClient(session: MockURLSession(data: Data(credentialsJSON.utf8), statusCode: 200)) }).listPasskeyCredentials()
        let users = try await AccountGateway.live(client: { self.makeClient(session: MockURLSession(data: Data(usersJSON.utf8), statusCode: 200)) }).listUsers()
        let revoked = try await AccountGateway.live(client: { self.makeClient(session: MockURLSession(data: Data(#"{"revoked_count":3}"#.utf8), statusCode: 200)) }).revokeOtherSessions()

        XCTAssertEqual(sessions, [
            DeviceSession(id: "sid-1", deviceLabel: "iPhone 15", createdAt: "2026-01-01T00:00:00Z", lastUsedAt: "2026-01-02T00:00:00Z", isCurrent: true),
            DeviceSession(id: "sid-2", deviceLabel: nil, createdAt: "2026-02-01T00:00:00Z", lastUsedAt: nil, isCurrent: false),
        ])
        XCTAssertEqual(receipt.token, "tok-login")
        XCTAssertEqual(receipt.subject.username, "alice")
        XCTAssertEqual(receipt.subject.role, .admin)
        XCTAssertEqual(receipt.subject.key, SubjectKey("u_alice-1"))
        XCTAssertEqual(credentials, [PasskeyCredential(id: "cred-1", name: "My Key", createdAt: "2026-03-01T00:00:00Z")])
        XCTAssertEqual(users, [Subject(username: "bob", displayName: "Bob", role: Role(rawValue: "x"), key: SubjectKey("u_bob"))])
        XCTAssertEqual(revoked, 3)
    }

    // MARK: - 要求の変換

    // verifies: ios-dec-107
    func testIosDec107_requestBodiesCarryArgumentsInPosition() async throws {
        let loginSession = MockURLSession(data: Data(loginJSON.utf8), statusCode: 200)
        _ = try await AccountGateway.live(client: { self.makeClient(session: loginSession) }).login("alice", "pw")
        let loginBody = try body(loginSession)
        XCTAssertEqual(loginBody["username"] as? String, "alice")
        XCTAssertEqual(loginBody["password"] as? String, "pw")

        let withoutName = MockURLSession(data: Data(userJSON.utf8), statusCode: 200)
        try await AccountGateway.live(client: { self.makeClient(session: withoutName) }).createUser("bob", "p", nil, .admin)
        let withoutNameBody = try body(withoutName)
        XCTAssertEqual(withoutNameBody["username"] as? String, "bob")
        XCTAssertEqual(withoutNameBody["password"] as? String, "p")
        XCTAssertEqual(withoutNameBody["role"] as? String, "admin")
        XCTAssertNil(withoutNameBody["display_name"], "nil の表示名は送らない")

        let withName = MockURLSession(data: Data(userJSON.utf8), statusCode: 200)
        try await AccountGateway.live(client: { self.makeClient(session: withName) }).createUser("bob", "p", "Bob", .user)
        let withNameBody = try body(withName)
        XCTAssertEqual(withNameBody["display_name"] as? String, "Bob")
        XCTAssertEqual(withNameBody["role"] as? String, "user")

        let patchSession = MockURLSession(data: Data(userJSON.utf8), statusCode: 200)
        try await AccountGateway.live(client: { self.makeClient(session: patchSession) }).updateUserRole("bob", .admin)
        XCTAssertEqual(patchSession.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(try body(patchSession)["role"] as? String, "admin")
    }

    // MARK: - 転送

    // verifies: ios-dec-107
    func testIosDec107_liveApiClientForwardsToLiveClient() async throws {
        let json = #"{"sessions":[{"id":"sid-1","device_label":"iPhone","created_at":"2026-01-01T00:00:00Z","last_used_at":null,"current":true}]}"#
        let client = makeClient(session: MockURLSession(data: Data(json.utf8), statusCode: 200))

        let viaApiClient = try await AccountGateway.live(apiClient: client).listSessions()
        let viaClosure = try await AccountGateway.live(client: { client }).listSessions()

        XCTAssertEqual(viaApiClient, viaClosure)
        XCTAssertEqual(viaApiClient.map(\.id), ["sid-1"])
    }

    // MARK: - 14 の closure の宛先と Passkey の変換

    // verifies: ios-dec-107, ios-cmd-account-08
    func testIosDec107_fourteenClosuresReachTheirEndpointsAndPasskeyIsConvertedInTheAdapter() async throws {
        let session = ScriptedURLSession()
        session.configure(method: "POST", path: "/auth/login", status: 200, body: Data(loginJSON.utf8))
        session.configure(method: "GET", path: "/auth/sessions", status: 200, body: Data(#"{"sessions":[]}"#.utf8))
        session.configure(method: "POST", path: "/auth/sessions/revoke-others", status: 200, body: Data(#"{"revoked_count":2}"#.utf8))
        session.configure(method: "POST", path: "/auth/passkey/register/options", status: 200, body: registrationOptionsResponse)
        session.configure(method: "POST", path: "/auth/passkey/login/options", status: 200, body: assertionOptionsResponse)
        session.configure(method: "POST", path: "/auth/passkey/login/verify", status: 200, body: Data(#"{"token":"tok-passkey","user":{"username":"alice","role":"user","display_name":"Alice"}}"#.utf8))
        session.configure(method: "GET", path: "/auth/passkey/credentials", status: 200, body: Data(#"{"credentials":[]}"#.utf8))
        session.configure(method: "GET", path: "/admin/users", status: 200, body: Data(#"{"users":[]}"#.utf8))
        session.configure(method: "POST", path: "/admin/users", status: 200, body: Data(userJSON.utf8))
        session.configure(method: "PATCH", path: "/admin/users/bob", status: 200, body: Data(userJSON.utf8))
        let gateway = AccountGateway.live(client: { self.makeClient(session: session) })
        let registrationCredential = MockPasskeyProvider.makeRegistrationCredential(
            credentialID: Data("reg-cid".utf8), clientDataJSON: Data("reg-cdj".utf8),
            attestationObject: Data("reg-att".utf8), transports: ["hybrid"]
        )
        let assertionCredential = MockPasskeyProvider.makeAssertionCredential(
            credentialID: Data("as-cid".utf8), clientDataJSON: Data("as-cdj".utf8),
            authenticatorData: Data("as-auth".utf8), signature: Data("as-sig".utf8), userHandle: Data("as-user".utf8)
        )

        _ = try await gateway.login("alice", "pw")
        _ = try await gateway.listSessions()
        try await gateway.revokeSession("s1")
        _ = try await gateway.revokeOtherSessions()
        let registerOptions = try await gateway.passkeyRegisterOptions()
        try await gateway.passkeyRegisterVerify("chal-reg-9", registrationCredential)
        let loginOptions = try await gateway.passkeyLoginOptions()
        let loginReceipt = try await gateway.passkeyLoginVerify("chal-login-9", assertionCredential)
        _ = try await gateway.listPasskeyCredentials()
        try await gateway.deletePasskeyCredential("c1")
        _ = try await gateway.listUsers()
        try await gateway.createUser("bob", "p", nil, .user)
        try await gateway.updateUserRole("bob", .admin)
        try await gateway.deleteUser("bob")

        let sent = session.sentRequests.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "?")" }
        XCTAssertEqual(sent, [
            "POST /auth/login",
            "GET /auth/sessions",
            "DELETE /auth/sessions/s1",
            "POST /auth/sessions/revoke-others",
            "POST /auth/passkey/register/options",
            "POST /auth/passkey/register/verify",
            "POST /auth/passkey/login/options",
            "POST /auth/passkey/login/verify",
            "GET /auth/passkey/credentials",
            "DELETE /auth/passkey/credentials/c1",
            "GET /admin/users",
            "POST /admin/users",
            "PATCH /admin/users/bob",
            "DELETE /admin/users/bob",
        ])

        XCTAssertEqual(registerOptions.challengeID, "chal-reg-9")
        XCTAssertEqual(registerOptions.options.rpID, "rp.example.com")
        XCTAssertEqual(loginOptions.challengeID, "chal-login-9")
        XCTAssertEqual(loginOptions.options.rpID, "rp-login.example.com")
        XCTAssertEqual(loginReceipt.token, "tok-passkey")

        let registerVerify = try verifyBody(session, path: "/auth/passkey/register/verify")
        XCTAssertEqual(registerVerify["challenge_id"] as? String, "chal-reg-9")
        let registerExpected = NSDictionary(dictionary: PasskeyCredentialEncoder.encodeRegistration(registrationCredential))
        XCTAssertTrue(registerExpected.isEqual(to: try XCTUnwrap(registerVerify["credential"] as? [String: Any])), "登録の credential は encoder の dict と等しい")

        let loginVerify = try verifyBody(session, path: "/auth/passkey/login/verify")
        XCTAssertEqual(loginVerify["challenge_id"] as? String, "chal-login-9")
        let loginExpected = NSDictionary(dictionary: PasskeyCredentialEncoder.encodeAssertion(assertionCredential))
        XCTAssertTrue(loginExpected.isEqual(to: try XCTUnwrap(loginVerify["credential"] as? [String: Any])), "認証の credential は encoder の dict と等しい")
    }

    private func verifyBody(_ session: ScriptedURLSession, path: String) throws -> [String: Any] {
        let request = try XCTUnwrap(session.sentRequests.first { $0.url?.path == path })
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
