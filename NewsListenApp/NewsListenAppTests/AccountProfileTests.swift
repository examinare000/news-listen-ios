import XCTest
@testable import NewsListenApp

/// AccountProfile（表示名の更新・パスワード変更の手順）と、その port の実体 `AccountGateway.live` のテスト。
@MainActor
final class AccountProfileTests: XCTestCase {

    private struct OtherError: Error, Equatable {}

    private final class GatewayRecorder {
        var updatedNames: [String] = []
        var changes: [(current: String, new: String)] = []
    }

    private let alice2 = Subject(username: "alice", displayName: "Alice2", role: Role(rawValue: "user"), key: nil)

    private func makeProfile(
        recorder: GatewayRecorder,
        updateResult: Result<Subject, Error>? = nil,
        changeError: Error? = nil
    ) -> AccountProfile {
        let subject = alice2
        return AccountProfile(gateway: AccountGateway(
            updateProfile: { name in
                recorder.updatedNames.append(name)
                return try (updateResult ?? .success(subject)).get()
            },
            changePassword: { current, new in
                recorder.changes.append((current, new))
                if let changeError { throw changeError }
            }
        ))
    }

    private func password(length: Int) -> String {
        String(repeating: "p", count: length)
    }

    private func makeLiveProfile(session: MockURLSession) -> AccountProfile {
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
        return AccountProfile(gateway: .live(apiClient: client))
    }

    private func requestBody(_ session: MockURLSession) throws -> [String: String] {
        let data = try XCTUnwrap(session.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    // MARK: - updateDisplayName

    // verifies: ios-cmd-account-05
    func testIosTest003_updateDisplayNameReturnsSubjectFromGateway() async throws {
        let recorder = GatewayRecorder()
        let profile = makeProfile(recorder: recorder)

        let subject = try await profile.updateDisplayName("Alice2")

        XCTAssertEqual(subject, alice2)
        XCTAssertEqual(recorder.updatedNames, ["Alice2"])
    }

    // verifies: ios-cmd-account-05
    func testIosCmdAccount05_updateDisplayNameWrapsApiFailureAndRethrowsOthers() async {
        let recorder = GatewayRecorder()
        let apiFailing = makeProfile(recorder: recorder, updateResult: .failure(ApiFailure.server(status: 500)))
        let otherFailing = makeProfile(recorder: recorder, updateResult: .failure(OtherError()))

        do {
            _ = try await apiFailing.updateDisplayName("x")
            XCTFail("ApiFailure は投げ直される")
        } catch {
            XCTAssertEqual(error as? AccountProfileFailure, .api(.server(status: 500)))
        }
        do {
            _ = try await otherFailing.updateDisplayName("x")
            XCTFail("別の error は投げ直される")
        } catch {
            XCTAssertEqual(error as? OtherError, OtherError())
        }
    }

    // MARK: - changePassword

    // verifies: ios-cmd-account-06
    func testIosTest104_changePasswordChecksPolicyBeforeGateway() async {
        let expectations: [(length: Int, failure: AccountProfileFailure)] = [
            (11, .policyViolation(.tooShort(minimum: 12))),
            (21, .policyViolation(.tooLong(maximum: 20))),
        ]
        for (length, expected) in expectations {
            let recorder = GatewayRecorder()
            let profile = makeProfile(recorder: recorder)

            do {
                try await profile.changePassword(current: "old", new: password(length: length))
                XCTFail("length \(length) は拒否される")
            } catch {
                XCTAssertEqual(error as? AccountProfileFailure, expected, "length \(length)")
            }
            XCTAssertTrue(recorder.changes.isEmpty, "length \(length) は gateway を呼ばない")
        }
    }

    // verifies: ios-cmd-account-06
    func testIosCmdAccount06_changePasswordCallsGatewayOnceAtBoundaries() async throws {
        for length in [12, 20] {
            let recorder = GatewayRecorder()
            let profile = makeProfile(recorder: recorder)
            let new = password(length: length)

            try await profile.changePassword(current: "old", new: new)

            XCTAssertEqual(recorder.changes.count, 1, "length \(length)")
            XCTAssertEqual(recorder.changes.first?.current, "old")
            XCTAssertEqual(recorder.changes.first?.new, new)
        }
    }

    // verifies: ios-cmd-account-06
    func testIosCmdAccount06_changePasswordMapsGatewayFailures() async {
        let cases: [(error: Error, check: (Error) -> Bool, label: String)] = [
            (ApiFailure.validation, { ($0 as? AccountProfileFailure) == .currentPasswordRejected }, "validation"),
            (ApiFailure.server(status: 500), { ($0 as? AccountProfileFailure) == .api(.server(status: 500)) }, "server"),
            (OtherError(), { ($0 as? OtherError) == OtherError() }, "other"),
        ]
        for (gatewayError, check, label) in cases {
            let profile = makeProfile(recorder: GatewayRecorder(), changeError: gatewayError)

            do {
                try await profile.changePassword(current: "old", new: password(length: 12))
                XCTFail("\(label) は失敗になる")
            } catch {
                XCTAssertTrue(check(error), "\(label): \(error)")
            }
        }
    }

    // MARK: - AccountGateway.live

    // verifies: ios-cmd-account-05
    func testIosCmdAccount05_liveGatewayPatchesMeAndMapsResponseToSubject() async throws {
        let json = #"{"username":"alice","role":"admin","display_name":"Alice2"}"#
        let session = MockURLSession(data: Data(json.utf8), statusCode: 200)
        let profile = makeLiveProfile(session: session)

        let subject = try await profile.updateDisplayName("Alice2")

        XCTAssertEqual(subject, Subject(username: "alice", displayName: "Alice2", role: Role(rawValue: "admin"), key: nil))
        XCTAssertEqual(session.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/me")
        XCTAssertEqual(try requestBody(session), ["display_name": "Alice2"])
    }

    // verifies: ios-cmd-account-06
    func testIosCmdAccount06_liveGatewayPostsPasswordPair() async throws {
        let session = MockURLSession(data: Data(), statusCode: 200)
        let profile = makeLiveProfile(session: session)
        let new = password(length: 12)

        try await profile.changePassword(current: "old", new: new)

        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(session.lastRequest?.url?.path, "/auth/password")
        XCTAssertEqual(try requestBody(session), ["current_password": "old", "new_password": new])
    }

    // verifies: ios-cmd-account-06
    func testIosCmdAccount06_liveGatewayMapsHttpFailures() async {
        let cases: [(status: Int, expected: AccountProfileFailure)] = [
            (400, .currentPasswordRejected),
            (500, .api(.server(status: 500))),
        ]
        for (status, expected) in cases {
            let profile = makeLiveProfile(session: MockURLSession(data: Data(), statusCode: status))

            do {
                try await profile.changePassword(current: "old", new: password(length: 12))
                XCTFail("status \(status) は失敗になる")
            } catch {
                XCTAssertEqual(error as? AccountProfileFailure, expected, "status \(status)")
            }
        }
    }
}
