import XCTest
@testable import NewsListenApp

/// `PasskeyEnrollment`（Passkey の登録・一覧・削除）の手順のテスト。登録の 409・削除の 404 の意味を固定する。
@MainActor
final class PasskeyEnrollmentTests: XCTestCase {

    private final class FlowRecorder {
        var events: [String] = []
        var createCountAtOptions: Int?
        var createCountAtVerify: Int?
        var verifiedChallengeID: String?
        var verifiedCredential: PasskeyRegistrationCredential?
        var deletedIDs: [String] = []
    }

    private let options = PasskeyRegistrationOptions(
        rpID: "rp.example.com",
        challenge: Data("gateway-challenge".utf8),
        userID: Data("uid".utf8),
        userName: "alice",
        userDisplayName: "Alice",
        excludeCredentialIDs: []
    )
    private let rows = [
        PasskeyCredential(id: "c1", name: "iPhone", createdAt: "2026-01-01T00:00:00Z"),
        PasskeyCredential(id: "c2", name: nil, createdAt: "2026-01-02T00:00:00Z"),
    ]

    private func makeProvider(create: Result<PasskeyRegistrationCredential, Error> = .success(MockPasskeyProvider.makeRegistrationCredential())) -> MockPasskeyProvider {
        let provider = MockPasskeyProvider()
        provider.createResult = create
        return provider
    }

    // verifies: ios-query-account-02
    func testIosQueryAccount02_credentialsReturnsGatewayRowsAndRethrowsFailure() async {
        let rows = self.rows
        let sut = PasskeyEnrollment(gateway: .stub(listPasskeyCredentials: { rows }), provider: makeProvider())
        let failing = PasskeyEnrollment(gateway: .stub(listPasskeyCredentials: { throw ApiFailure.server(status: 500) }), provider: makeProvider())

        let listed = try? await sut.credentials()

        XCTAssertEqual(listed, rows)
        do {
            _ = try await failing.credentials()
            XCTFail("失敗は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    // verifies: ios-cmd-account-08, ios-test-005
    func testIosTest005_registerRunsOptionsThenCreateThenVerifyAndForwardsProviderCredential() async throws {
        let recorder = FlowRecorder()
        let options = self.options
        let credential = MockPasskeyProvider.makeRegistrationCredential(
            credentialID: Data("cid-X".utf8),
            clientDataJSON: Data("cdj-X".utf8),
            attestationObject: Data("att-X".utf8),
            transports: ["hybrid", "usb"]
        )
        let provider = makeProvider(create: .success(credential))
        let sut = PasskeyEnrollment(
            gateway: .stub(
                passkeyRegisterOptions: {
                    recorder.events.append("options")
                    recorder.createCountAtOptions = provider.createCallCount
                    return (challengeID: "chal-reg", options: options)
                },
                passkeyRegisterVerify: { challengeID, credential in
                    recorder.events.append("verify")
                    recorder.createCountAtVerify = provider.createCallCount
                    recorder.verifiedChallengeID = challengeID
                    recorder.verifiedCredential = credential
                }
            ),
            provider: provider
        )

        try await sut.register()

        XCTAssertEqual(recorder.events, ["options", "verify"])
        XCTAssertEqual(recorder.createCountAtOptions, 0)
        XCTAssertEqual(recorder.createCountAtVerify, 1)
        XCTAssertEqual(provider.receivedRegistrationOptions?.rpID, options.rpID)
        XCTAssertEqual(provider.receivedRegistrationOptions?.challenge, options.challenge)
        XCTAssertEqual(recorder.verifiedChallengeID, "chal-reg")
        XCTAssertEqual(recorder.verifiedCredential?.credentialID, Data("cid-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.clientDataJSON, Data("cdj-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.attestationObject, Data("att-X".utf8))
        XCTAssertEqual(recorder.verifiedCredential?.transports, ["hybrid", "usb"])
    }

    // verifies: ios-cmd-account-08, ios-rule-account-06
    func testIosRuleAccount06_registerConflictBecomesAlreadyRegisteredForVerifyAndOptions() async {
        let options = self.options
        let conflictOnVerify = PasskeyEnrollment(
            gateway: .stub(
                passkeyRegisterOptions: { (challengeID: "c", options: options) },
                passkeyRegisterVerify: { _, _ in throw ApiFailure.conflict }
            ),
            provider: makeProvider()
        )
        let conflictOnOptions = PasskeyEnrollment(
            gateway: .stub(passkeyRegisterOptions: { throw ApiFailure.conflict }),
            provider: makeProvider()
        )

        for (label, sut) in [("verify", conflictOnVerify), ("options", conflictOnOptions)] {
            do {
                try await sut.register()
                XCTFail("\(label) の 409 は成功にならない")
            } catch {
                XCTAssertEqual(error as? PasskeyEnrollmentFailure, .alreadyRegistered, label)
            }
        }
    }

    // verifies: ios-cmd-account-08
    func testIosCmdAccount08_registerCancelIsRethrownWithoutVerifyAndOtherFailuresAreUnchanged() async {
        let options = self.options
        let recorder = FlowRecorder()
        let canceled = PasskeyEnrollment(
            gateway: .stub(
                passkeyRegisterOptions: { (challengeID: "c", options: options) },
                passkeyRegisterVerify: { _, _ in recorder.events.append("verify") }
            ),
            provider: makeProvider(create: .failure(PasskeyError.canceled))
        )
        let serverOnVerify = PasskeyEnrollment(
            gateway: .stub(
                passkeyRegisterOptions: { (challengeID: "c", options: options) },
                passkeyRegisterVerify: { _, _ in throw ApiFailure.server(status: 500) }
            ),
            provider: makeProvider()
        )

        do {
            try await canceled.register()
            XCTFail("取消は投げられる")
        } catch {
            guard case PasskeyError.canceled = error else { return XCTFail("取消のまま投げる: \(error)") }
        }
        XCTAssertEqual(recorder.events, [], "取消の後に verify を呼ばない")
        do {
            try await serverOnVerify.register()
            XCTFail("500 は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    // verifies: ios-cmd-account-08, ios-rule-account-06
    func testIosRuleAccount06_deleteTreatsCredentialNotFoundAsSuccess() async throws {
        let recorder = FlowRecorder()
        let notFound = PasskeyEnrollment(gateway: .stub(deletePasskeyCredential: { id in
            recorder.deletedIDs.append(id)
            throw ApiFailure.notFound(subject: .credential)
        }), provider: makeProvider())
        let ok = PasskeyEnrollment(gateway: .stub(deletePasskeyCredential: { id in recorder.deletedIDs.append(id) }), provider: makeProvider())

        try await notFound.delete(id: "c1")
        try await ok.delete(id: "c1")

        XCTAssertEqual(recorder.deletedIDs, ["c1", "c1"])
    }

    // verifies: ios-rule-account-06
    func testIosRuleAccount06_deleteRethrowsOtherFailuresUnchanged() async {
        let cases: [ApiFailure] = [.server(status: 500), .notFound(subject: .session)]
        for failure in cases {
            let sut = PasskeyEnrollment(gateway: .stub(deletePasskeyCredential: { _ in throw failure }), provider: makeProvider())

            do {
                try await sut.delete(id: "c1")
                XCTFail("\(failure) は投げられる")
            } catch {
                XCTAssertEqual(error as? ApiFailure, failure)
            }
        }
    }

    // verifies: ios-check-07, ios-test-108
    func testIosTest108_mutatingReturnedRowsDoesNotChangeNextCredentials() async throws {
        let rows = self.rows
        let sut = PasskeyEnrollment(gateway: .stub(listPasskeyCredentials: { rows }), provider: makeProvider())

        var first = try await sut.credentials()
        first.removeAll()
        let second = try await sut.credentials()

        XCTAssertEqual(second, rows)
    }
}
