import XCTest
@testable import NewsListenApp

/// `Authentication`（パスワードのログイン）の手順のテスト。通信は `AccountGateway` の向こうに置く。
@MainActor
final class AuthenticationTests: XCTestCase {

    private final class LoginRecorder {
        var calls: [(username: String, password: String)] = []
    }

    private let receipt = LoginReceipt(
        token: "tok-1",
        subject: Subject(username: "alice", displayName: "Alice", role: .user, key: SubjectKey("u_alice"))
    )

    // verifies: ios-cmd-account-01, ios-test-001
    func testIosTest001_loginReturnsGatewayReceiptWithArgumentsUnchanged() async throws {
        let recorder = LoginRecorder()
        let receipt = self.receipt
        let sut = Authentication(gateway: .stub(login: { username, password in
            recorder.calls.append((username, password))
            return receipt
        }))

        let result = try await sut.login(username: "alice", password: "pw")

        XCTAssertEqual(result, receipt)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.username, "alice")
        XCTAssertEqual(recorder.calls.first?.password, "pw")
    }

    // verifies: ios-cmd-account-01, ios-test-001
    func testIosTest001_loginRethrowsApiFailureUnchanged() async {
        let sut = Authentication(gateway: .stub(login: { _, _ in throw ApiFailure.unauthorized }))

        do {
            _ = try await sut.login(username: "alice", password: "wrong")
            XCTFail("失敗は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .unauthorized)
        }
    }
}
