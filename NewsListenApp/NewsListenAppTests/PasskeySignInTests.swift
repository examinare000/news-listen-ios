import XCTest
@testable import NewsListenApp

/// `PasskeySignIn`（Passkey のログイン）の手順のテスト。options → 認証器 → verify の順と、provider の credential の転送を固定する。
@MainActor
final class PasskeySignInTests: XCTestCase {

    private final class FlowRecorder {
        var events: [String] = []
        var assertCountAtOptions: Int?
        var assertCountAtVerify: Int?
        var verifiedChallengeID: String?
        var verifiedCredential: PasskeyAssertionCredential?
    }

    private let options = PasskeyAssertionOptions(
        rpID: "rp.example.com",
        challenge: Data("gateway-challenge".utf8),
        allowCredentialIDs: []
    )
    private let receipt = LoginReceipt(
        token: "tok-passkey",
        subject: Subject(username: "alice", displayName: "Alice", role: .user, key: nil)
    )

    private func makeSignIn(recorder: FlowRecorder, provider: MockPasskeyProvider) -> PasskeySignIn {
        let options = self.options
        let receipt = self.receipt
        return PasskeySignIn(
            gateway: .stub(
                passkeyLoginOptions: {
                    recorder.events.append("options")
                    recorder.assertCountAtOptions = provider.assertCallCount
                    return (challengeID: "chal-1", options: options)
                },
                passkeyLoginVerify: { challengeID, credential in
                    recorder.events.append("verify")
                    recorder.assertCountAtVerify = provider.assertCallCount
                    recorder.verifiedChallengeID = challengeID
                    recorder.verifiedCredential = credential
                    return receipt
                }
            ),
            provider: provider
        )
    }

    // verifies: ios-cmd-account-01, ios-test-001
    func testIosTest001_signInRunsOptionsThenAssertThenVerifyAndForwardsProviderCredential() async throws {
        let recorder = FlowRecorder()
        let provider = MockPasskeyProvider()
        let credential = MockPasskeyProvider.makeAssertionCredential(
            credentialID: Data("cid-X".utf8),
            clientDataJSON: Data("cdj-X".utf8),
            authenticatorData: Data("auth-X".utf8),
            signature: Data("sig-X".utf8),
            userHandle: Data("handle-X".utf8)
        )
        provider.assertResult = .success(credential)
        let sut = makeSignIn(recorder: recorder, provider: provider)

        let result = try await sut.signIn()

        XCTAssertEqual(recorder.events, ["options", "verify"])
        XCTAssertEqual(recorder.assertCountAtOptions, 0, "options の時点で認証器は未呼出")
        XCTAssertEqual(recorder.assertCountAtVerify, 1, "verify の時点で認証器は 1 回呼ばれている")
        XCTAssertEqual(provider.receivedAssertionOptions?.rpID, options.rpID)
        XCTAssertEqual(provider.receivedAssertionOptions?.challenge, options.challenge)
        XCTAssertEqual(recorder.verifiedChallengeID, "chal-1")
        XCTAssertEqual(recorder.verifiedCredential?.credentialID, Data("cid-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.clientDataJSON, Data("cdj-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.authenticatorData, Data("auth-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.signature, Data("sig-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.userHandle, Data("handle-X".utf8))
        XCTAssertEqual(result, receipt)
    }

    // verifies: ios-cmd-account-01, ios-test-001
    func testIosTest001_signInCancelIsRethrownAndVerifyIsNotCalled() async {
        let recorder = FlowRecorder()
        let provider = MockPasskeyProvider()
        provider.assertResult = .failure(PasskeyError.canceled)
        let sut = makeSignIn(recorder: recorder, provider: provider)

        do {
            _ = try await sut.signIn()
            XCTFail("取消は投げられる")
        } catch {
            guard case PasskeyError.canceled = error else { return XCTFail("取消のまま投げる: \(error)") }
        }
        XCTAssertEqual(recorder.events, ["options"], "取消の後に verify を呼ばない")
    }

    // verifies: ios-cmd-account-01, ios-test-001
    func testIosTest001_signInRethrowsGatewayFailuresUnchanged() async {
        let provider = MockPasskeyProvider()
        provider.assertResult = .success(MockPasskeyProvider.makeAssertionCredential())
        let options = self.options

        let conflictOnVerify = PasskeySignIn(
            gateway: .stub(
                passkeyLoginOptions: { (challengeID: "c", options: options) },
                passkeyLoginVerify: { _, _ in throw ApiFailure.conflict }
            ),
            provider: provider
        )
        let serverOnOptions = PasskeySignIn(
            gateway: .stub(passkeyLoginOptions: { throw ApiFailure.server(status: 500) }),
            provider: provider
        )

        do {
            _ = try await conflictOnVerify.signIn()
            XCTFail("verify の失敗は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .conflict, "409 も変換しない")
        }
        do {
            _ = try await serverOnOptions.signIn()
            XCTFail("options の失敗は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
        XCTAssertEqual(provider.assertCallCount, 1, "options が失敗したときは認証器を呼ばない")
    }
}
