import XCTest
@testable import NewsListenApp

// MARK: - Base64URL Tests

/// Data ↔ base64url 純粋変換のテスト。
final class Base64URLTests: XCTestCase {

    // MARK: Encode

    func testEncodeKnownBytes() {
        // "challenge" → base64url = Y2hhbGxlbmdl（パディング不要: 9 bytes → 12 chars）
        let data = Data("challenge".utf8)
        XCTAssertEqual(data.base64URLEncodedString(), "Y2hhbGxlbmdl")
    }

    func testEncodeUsesURLSafeCharsNotStandardBase64() {
        // 標準 base64 の '+' → '-', '/' → '_' に置換されること。
        // 0xFB = 11111011, 0xEF = 11101111 → standard base64 "++" → URL-safe "--"
        let data = Data([0xFB, 0xEF])
        let encoded = data.base64URLEncodedString()
        XCTAssertFalse(encoded.contains("+"), "'+' は URL-safe '-' に置換されること")
        XCTAssertFalse(encoded.contains("/"), "'/' は URL-safe '_' に置換されること")
    }

    func testEncodeHasNoPadding() {
        // 1 byte, 2 bytes でも '=' パディングが含まれないこと。
        XCTAssertFalse(Data([0x01]).base64URLEncodedString().contains("="))
        XCTAssertFalse(Data([0x01, 0x02]).base64URLEncodedString().contains("="))
    }

    func testEncodeEmptyDataReturnsEmptyString() {
        XCTAssertEqual(Data().base64URLEncodedString(), "")
    }

    // MARK: Decode

    func testDecodeKnownBase64URL() {
        // Y2hhbGxlbmdl → "challenge"
        let decoded = Data(base64URLEncoded: "Y2hhbGxlbmdl")
        XCTAssertEqual(decoded, Data("challenge".utf8))
    }

    func testDecodeURLSafeChars() {
        // URL-safe 文字 '-', '_' を含む文字列が正しくデコードされること。
        let encoded = Data([0xFB, 0xEF]).base64URLEncodedString()
        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, Data([0xFB, 0xEF]))
    }

    func testDecodePaddingOptional() {
        // パディングあり/なし両方が受け付けられること（base64url はパディング不要）。
        let base64 = "Y2hhbGxlbmdl"
        XCTAssertNotNil(Data(base64URLEncoded: base64))
        XCTAssertNotNil(Data(base64URLEncoded: base64 + "="))  // optional padding ok
    }

    func testDecodeInvalidStringReturnsNil() {
        XCTAssertNil(Data(base64URLEncoded: "!!!invalid!!!"))
    }

    func testDecodeEmptyStringReturnsEmptyData() {
        XCTAssertEqual(Data(base64URLEncoded: ""), Data())
    }

    // MARK: Round-trip

    func testRoundTripArbitraryBytes() {
        let original = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let encoded = original.base64URLEncodedString()
        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, original, "encode→decode のラウンドトリップで元データと一致すること")
    }
}

// MARK: - PasskeyOptionsDecoder Tests

/// PasskeyOptionsDecoder の純粋デコードのテスト。
/// バックエンド python-webauthn が生成する JSON 文字列（二段パース）を検証する。
final class PasskeyOptionsDecoderTests: XCTestCase {

    // MARK: Helpers

    /// バックエンドが返す認証オプション（AssertionOptions）APIレスポンスを生成する。
    /// options フィールドは JSON 文字列として python-webauthn 形式で組み立てる。
    private func makeLoginOptionsAPIResponse(
        challengeID: String = "chal-id-login",
        rpID: String = "rp.example.com",
        challengeBase64URL: String = "Y2hhbGxlbmdl",
        allowCredentials: [[String: String]] = []
    ) -> PasskeyOptionsAPIResponse {
        let innerOptions: [String: Any] = [
            "rpId": rpID,
            "challenge": challengeBase64URL,
            "allowCredentials": allowCredentials,
            "timeout": 60000,
            "userVerification": "required"
        ]
        let optionsStr = String(data: try! JSONSerialization.data(withJSONObject: innerOptions), encoding: .utf8)!
        return PasskeyOptionsAPIResponse(challengeID: challengeID, options: optionsStr)
    }

    /// バックエンドが返す登録オプション（RegistrationOptions）APIレスポンスを生成する。
    private func makeRegisterOptionsAPIResponse(
        challengeID: String = "chal-id-reg",
        rpID: String = "rp.example.com",
        rpName: String = "News Listen",
        challengeBase64URL: String = "Y2hhbGxlbmdl",
        userIDBase64URL: String = "dXNlcklE",
        userName: String = "alice",
        userDisplayName: String = "Alice",
        excludeCredentials: [[String: String]] = []
    ) -> PasskeyOptionsAPIResponse {
        let innerOptions: [String: Any] = [
            "rp": ["id": rpID, "name": rpName],
            "user": [
                "id": userIDBase64URL,
                "name": userName,
                "displayName": userDisplayName
            ],
            "challenge": challengeBase64URL,
            "pubKeyCredParams": [["type": "public-key", "alg": -7]],
            "timeout": 60000,
            "excludeCredentials": excludeCredentials,
            "attestation": "none",
            "authenticatorSelection": [
                "residentKey": "required",
                "requireResidentKey": true,
                "userVerification": "required"
            ]
        ]
        let optionsStr = String(data: try! JSONSerialization.data(withJSONObject: innerOptions), encoding: .utf8)!
        return PasskeyOptionsAPIResponse(challengeID: challengeID, options: optionsStr)
    }

    // MARK: Assertion (Login) Decode

    func testDecodeAssertionChallengeDecodesBase64URL() throws {
        // "Y2hhbGxlbmdl" → base64url デコード → Data("challenge")
        let response = makeLoginOptionsAPIResponse(challengeBase64URL: "Y2hhbGxlbmdl")
        let options = try PasskeyOptionsDecoder.decodeAssertion(from: response)
        XCTAssertEqual(options.challenge, Data("challenge".utf8))
    }

    func testDecodeAssertionRpID() throws {
        let response = makeLoginOptionsAPIResponse(rpID: "api.my-app.com")
        let options = try PasskeyOptionsDecoder.decodeAssertion(from: response)
        XCTAssertEqual(options.rpID, "api.my-app.com")
    }

    func testDecodeAssertionAllowCredentialsEmpty() throws {
        // allowCredentials が空のとき（discoverable フロー）空配列を返すこと。
        let response = makeLoginOptionsAPIResponse(allowCredentials: [])
        let options = try PasskeyOptionsDecoder.decodeAssertion(from: response)
        XCTAssertEqual(options.allowCredentialIDs, [])
    }

    func testDecodeAssertionAllowCredentialsWithEntries() throws {
        // allowCredentials に要素がある場合、base64url デコードして返すこと。
        let credID = "Y2hhbGxlbmdl"  // = Data("challenge")
        let response = makeLoginOptionsAPIResponse(allowCredentials: [["type": "public-key", "id": credID]])
        let options = try PasskeyOptionsDecoder.decodeAssertion(from: response)
        XCTAssertEqual(options.allowCredentialIDs, [Data("challenge".utf8)])
    }

    func testDecodeAssertionThrowsOnMalformedOptionsJSON() {
        let response = PasskeyOptionsAPIResponse(challengeID: "chal", options: "not valid json {{")
        XCTAssertThrowsError(try PasskeyOptionsDecoder.decodeAssertion(from: response))
    }

    // MARK: Registration Decode

    func testDecodeRegistrationChallengeDecodesBase64URL() throws {
        let response = makeRegisterOptionsAPIResponse(challengeBase64URL: "Y2hhbGxlbmdl")
        let options = try PasskeyOptionsDecoder.decodeRegistration(from: response)
        XCTAssertEqual(options.challenge, Data("challenge".utf8))
    }

    func testDecodeRegistrationRpID() throws {
        let response = makeRegisterOptionsAPIResponse(rpID: "api.my-app.com")
        let options = try PasskeyOptionsDecoder.decodeRegistration(from: response)
        XCTAssertEqual(options.rpID, "api.my-app.com")
    }

    func testDecodeRegistrationUserID() throws {
        // "dXNlcklE" = base64url("userID")
        let response = makeRegisterOptionsAPIResponse(userIDBase64URL: "dXNlcklE")
        let options = try PasskeyOptionsDecoder.decodeRegistration(from: response)
        XCTAssertEqual(options.userID, Data("userID".utf8))
    }

    func testDecodeRegistrationUserNameAndDisplayName() throws {
        let response = makeRegisterOptionsAPIResponse(userName: "bob", userDisplayName: "Bob Smith")
        let options = try PasskeyOptionsDecoder.decodeRegistration(from: response)
        XCTAssertEqual(options.userName, "bob")
        XCTAssertEqual(options.userDisplayName, "Bob Smith")
    }

    func testDecodeRegistrationExcludeCredentialsEmpty() throws {
        let response = makeRegisterOptionsAPIResponse(excludeCredentials: [])
        let options = try PasskeyOptionsDecoder.decodeRegistration(from: response)
        XCTAssertEqual(options.excludeCredentialIDs, [])
    }

    func testDecodeRegistrationExcludeCredentialsWithEntries() throws {
        let credID = "Y2hhbGxlbmdl"
        let response = makeRegisterOptionsAPIResponse(
            excludeCredentials: [["type": "public-key", "id": credID]]
        )
        let options = try PasskeyOptionsDecoder.decodeRegistration(from: response)
        XCTAssertEqual(options.excludeCredentialIDs, [Data("challenge".utf8)])
    }

    func testDecodeRegistrationThrowsOnMalformedOptionsJSON() {
        let response = PasskeyOptionsAPIResponse(challengeID: "chal", options: "{broken json")
        XCTAssertThrowsError(try PasskeyOptionsDecoder.decodeRegistration(from: response))
    }
}

// MARK: - PasskeyCredentialEncoder Tests

/// PasskeyCredentialEncoder の pure 変換のテスト。
/// バックエンドの verify endpoint へ送るリクエスト dict の形式を検証する。
final class PasskeyCredentialEncoderTests: XCTestCase {

    // MARK: Helpers

    private func makeAssertionCredential(
        credentialID: Data = Data("cred-id".utf8),
        clientDataJSON: Data = Data("clientData".utf8),
        authenticatorData: Data = Data("authData".utf8),
        signature: Data = Data("sig".utf8),
        userHandle: Data? = Data("user-handle".utf8)
    ) -> PasskeyAssertionCredential {
        PasskeyAssertionCredential(
            credentialID: credentialID,
            clientDataJSON: clientDataJSON,
            authenticatorData: authenticatorData,
            signature: signature,
            userHandle: userHandle
        )
    }

    private func makeRegistrationCredential(
        credentialID: Data = Data("cred-id".utf8),
        clientDataJSON: Data = Data("clientData".utf8),
        attestationObject: Data = Data("attest".utf8),
        transports: [String] = ["internal", "hybrid"]
    ) -> PasskeyRegistrationCredential {
        PasskeyRegistrationCredential(
            credentialID: credentialID,
            clientDataJSON: clientDataJSON,
            attestationObject: attestationObject,
            transports: transports
        )
    }

    // MARK: Registration encode

    func testRegistrationEncodesIDAsBase64URL() {
        let cred = makeRegistrationCredential(credentialID: Data("cred-id".utf8))
        let dict = PasskeyCredentialEncoder.encodeRegistration(cred)
        let expected = Data("cred-id".utf8).base64URLEncodedString()
        XCTAssertEqual(dict["id"] as? String, expected)
        XCTAssertEqual(dict["rawId"] as? String, expected, "id と rawId は同値であること")
    }

    func testRegistrationTypeIsPublicKey() {
        let dict = PasskeyCredentialEncoder.encodeRegistration(makeRegistrationCredential())
        XCTAssertEqual(dict["type"] as? String, "public-key")
    }

    func testRegistrationResponseContainsClientDataJSON() {
        let cred = makeRegistrationCredential(clientDataJSON: Data("clientData".utf8))
        let dict = PasskeyCredentialEncoder.encodeRegistration(cred)
        let resp = dict["response"] as? [String: Any]
        let expected = Data("clientData".utf8).base64URLEncodedString()
        XCTAssertEqual(resp?["clientDataJSON"] as? String, expected)
    }

    func testRegistrationResponseContainsAttestationObject() {
        let cred = makeRegistrationCredential(attestationObject: Data("attest".utf8))
        let dict = PasskeyCredentialEncoder.encodeRegistration(cred)
        let resp = dict["response"] as? [String: Any]
        let expected = Data("attest".utf8).base64URLEncodedString()
        XCTAssertEqual(resp?["attestationObject"] as? String, expected)
    }

    func testRegistrationResponseContainsTransports() {
        let cred = makeRegistrationCredential(transports: ["internal", "hybrid"])
        let dict = PasskeyCredentialEncoder.encodeRegistration(cred)
        let resp = dict["response"] as? [String: Any]
        XCTAssertEqual(resp?["transports"] as? [String], ["internal", "hybrid"])
    }

    // MARK: Assertion encode

    func testAssertionEncodesIDAsBase64URL() {
        let cred = makeAssertionCredential(credentialID: Data("cred-id".utf8))
        let dict = PasskeyCredentialEncoder.encodeAssertion(cred)
        let expected = Data("cred-id".utf8).base64URLEncodedString()
        XCTAssertEqual(dict["id"] as? String, expected)
        XCTAssertEqual(dict["rawId"] as? String, expected)
    }

    func testAssertionTypeIsPublicKey() {
        let dict = PasskeyCredentialEncoder.encodeAssertion(makeAssertionCredential())
        XCTAssertEqual(dict["type"] as? String, "public-key")
    }

    func testAssertionResponseContainsClientDataJSONAuthDataSignature() {
        let cred = makeAssertionCredential(
            clientDataJSON: Data("clientData".utf8),
            authenticatorData: Data("authData".utf8),
            signature: Data("sig".utf8)
        )
        let resp = PasskeyCredentialEncoder.encodeAssertion(cred)["response"] as? [String: Any]
        XCTAssertEqual(resp?["clientDataJSON"] as? String, Data("clientData".utf8).base64URLEncodedString())
        XCTAssertEqual(resp?["authenticatorData"] as? String, Data("authData".utf8).base64URLEncodedString())
        XCTAssertEqual(resp?["signature"] as? String, Data("sig".utf8).base64URLEncodedString())
    }

    func testAssertionResponseContainsUserHandleWhenPresent() {
        let cred = makeAssertionCredential(userHandle: Data("user-handle".utf8))
        let resp = PasskeyCredentialEncoder.encodeAssertion(cred)["response"] as? [String: Any]
        XCTAssertEqual(resp?["userHandle"] as? String, Data("user-handle".utf8).base64URLEncodedString())
    }

    func testAssertionResponseOmitsUserHandleWhenNil() {
        let cred = makeAssertionCredential(userHandle: nil)
        let resp = PasskeyCredentialEncoder.encodeAssertion(cred)["response"] as? [String: Any]
        XCTAssertNil(resp?["userHandle"], "userHandle が nil のとき response dict に含まれないこと")
    }

    // MARK: JSONSerialization 適合確認

    func testRegistrationDictIsJSONSerializable() throws {
        let cred = makeRegistrationCredential()
        let dict = PasskeyCredentialEncoder.encodeRegistration(cred)
        // バックエンドへ送る前に JSONSerialization でシリアライズできること（ネスト dict も含む）。
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: dict))
    }

    func testAssertionDictIsJSONSerializable() throws {
        let cred = makeAssertionCredential()
        let dict = PasskeyCredentialEncoder.encodeAssertion(cred)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: dict))
    }
}

// MARK: - Codable Response Tests

/// PasskeyOptionsAPIResponse と PasskeyCredentialsAPIResponse の Codable テスト。
final class PasskeyResponseCodableTests: XCTestCase {

    func testPasskeyOptionsAPIResponseDecodes() throws {
        // バックエンドが返す外側 JSON（options は文字列）をデコードできること。
        let innerJSON = #"{"rpId":"rp.example.com","challenge":"Y2hhbGxlbmdl","allowCredentials":[]}"#
        let outerJSON: [String: Any] = ["challenge_id": "chal-123", "options": innerJSON]
        let data = try JSONSerialization.data(withJSONObject: outerJSON)

        let decoded = try JSONDecoder().decode(PasskeyOptionsAPIResponse.self, from: data)

        XCTAssertEqual(decoded.challengeID, "chal-123")
        // options はそのままの文字列として保持されていること（内部 JSON はまだ未パース）。
        XCTAssertTrue(decoded.options.contains("rpId"), "options 文字列に rpId が含まれること")
    }

    func testPasskeyCredentialsAPIResponseDecodes() throws {
        let json = """
        {"credentials":[
            {"credential_id":"cred-abc","username":"alice","name":null,"transports":["internal"],
             "aaguid":null,"sign_count":5,"created_at":"2026-01-01T00:00:00Z","last_used_at":null}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            PasskeyCredentialsAPIResponse.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(decoded.credentials.count, 1)
        XCTAssertEqual(decoded.credentials[0].credentialID, "cred-abc")
        XCTAssertEqual(decoded.credentials[0].username, "alice")
        XCTAssertNil(decoded.credentials[0].name)
        XCTAssertEqual(decoded.credentials[0].transports, ["internal"])
        XCTAssertEqual(decoded.credentials[0].signCount, 5)
        XCTAssertNil(decoded.credentials[0].lastUsedAt)
    }
}
