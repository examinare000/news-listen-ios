import XCTest
@testable import NewsListenApp

/// PasskeyLoginViewModel のテスト（AC ★コア）。
/// 仕様: options 取得 → provider.assertCredential（受け取ったオプションの整合確認）
///       → verify → onSuccess(token) の正常系と各異常系。
@MainActor
final class PasskeyLoginViewModelTests: XCTestCase {

    // MARK: - Test fixtures

    /// サーバから返る認証 options の内側 JSON（python-webauthn 形式）。
    private let innerAssertionOptionsJSON = """
    {"rpId":"rp.example.com","challenge":"Y2hhbGxlbmdl","allowCredentials":[],"timeout":60000,"userVerification":"required"}
    """

    /// POST /auth/passkey/login/options レスポンス JSON（options は文字列化 JSON）。
    private var optionsResponseData: Data {
        let outer: [String: Any] = ["challenge_id": "chal-login-1", "options": innerAssertionOptionsJSON]
        return try! JSONSerialization.data(withJSONObject: outer)
    }

    /// POST /auth/passkey/login/verify 成功レスポンス。
    private let loginResponseData = #"{"token":"tok-passkey","user":{"username":"alice","role":"user","display_name":"Alice"}}"#
        .data(using: .utf8)!

    /// 正常系のシーケンシャルセッション（options → verify の2往復）。
    private var happyPathSession: SequentialMockSession {
        SequentialMockSession([
            .init(data: optionsResponseData, statusCode: 200),
            .init(data: loginResponseData, statusCode: 200)
        ])
    }

    private func makeClient(session: URLSessionProtocol, token: String = "current-tok") -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: token,
            session: session
        )
    }

    // MARK: - 正常系

    func testSuccessfulLoginCallsOnSuccessWithToken() async {
        // Arrange
        let provider = MockPasskeyProvider()
        provider.assertResult = .success(MockPasskeyProvider.makeAssertionCredential())
        var captured: LoginResponse?

        let vm = PasskeyLoginViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { captured = $0 }
        )

        // Act
        await vm.performLogin()

        // Assert
        XCTAssertEqual(captured?.token, "tok-passkey")
        XCTAssertEqual(captured?.user.username, "alice")
        XCTAssertNil(vm.errorMessage, "正常系でエラーメッセージが表示されないこと")
    }

    func testSuccessfulLoginPassesCorrectOptionsToProvider() async {
        // provider が受け取った options がデコード結果と一致すること（記録 options 整合確認）。
        let provider = MockPasskeyProvider()
        provider.assertResult = .success(MockPasskeyProvider.makeAssertionCredential())

        let vm = PasskeyLoginViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { _ in }
        )

        await vm.performLogin()

        // backend から送られた challenge の base64url デコード結果と一致すること。
        XCTAssertEqual(
            provider.receivedAssertionOptions?.challenge,
            Data("challenge".utf8),
            "Y2hhbGxlbmdl をデコードした Data と一致すること"
        )
        XCTAssertEqual(provider.receivedAssertionOptions?.rpID, "rp.example.com")
        XCTAssertEqual(provider.receivedAssertionOptions?.allowCredentialIDs, [])
        XCTAssertEqual(provider.assertCallCount, 1)
    }

    // MARK: - 異常系: API 401

    func testAPIErrorSetsErrorMessageAndDoesNotCallOnSuccess() async {
        // login/options が 401 を返した場合、汎用エラーメッセージが設定されること。
        let session = SequentialMockSession([.init(data: Data(), statusCode: 401)])
        let provider = MockPasskeyProvider()
        var successCalled = false

        let vm = PasskeyLoginViewModel(
            apiClient: makeClient(session: session),
            provider: provider,
            onSuccess: { _ in successCalled = true }
        )

        await vm.performLogin()

        XCTAssertFalse(successCalled, "API 失敗時は onSuccess が呼ばれないこと")
        XCTAssertNotNil(vm.errorMessage, "API 失敗時はエラーメッセージが設定されること")
        XCTAssertEqual(provider.assertCallCount, 0, "API 失敗時は provider が呼ばれないこと")
    }

    // MARK: - 異常系: ユーザーキャンセル

    func testUserCancelDoesNotSetErrorMessageAndDoesNotCallOnSuccess() async {
        // PasskeyError.canceled は「失敗扱いしない」: errorMessage を設定しないこと。
        let provider = MockPasskeyProvider()
        provider.assertResult = .failure(PasskeyError.canceled)
        var successCalled = false

        let vm = PasskeyLoginViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { _ in successCalled = true }
        )

        await vm.performLogin()

        XCTAssertFalse(successCalled, "キャンセル時は onSuccess が呼ばれないこと")
        XCTAssertNil(vm.errorMessage, "キャンセルはエラー扱いしないため errorMessage は nil であること")
        XCTAssertFalse(vm.isRunning, "キャンセル後は isRunning が false に戻ること")
    }

    // MARK: - 異常系: provider 失敗

    func testProviderFailedSetsErrorMessage() async {
        // PasskeyError.failed は認証エラーとして errorMessage を設定すること。
        struct FakeError: Error {}
        let provider = MockPasskeyProvider()
        provider.assertResult = .failure(PasskeyError.failed(FakeError()))
        var successCalled = false

        let vm = PasskeyLoginViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { _ in successCalled = true }
        )

        await vm.performLogin()

        XCTAssertFalse(successCalled, "provider 失敗時は onSuccess が呼ばれないこと")
        XCTAssertNotNil(vm.errorMessage, "provider 失敗時はエラーメッセージが設定されること")
    }

    // MARK: - isRunning 状態管理

    func testIsRunningIsFalseBetweenRuns() async {
        let session = SequentialMockSession([.init(data: Data(), statusCode: 500)])
        let provider = MockPasskeyProvider()
        let vm = PasskeyLoginViewModel(
            apiClient: makeClient(session: session),
            provider: provider,
            onSuccess: { _ in }
        )

        XCTAssertFalse(vm.isRunning, "開始前は isRunning = false")
        await vm.performLogin()
        XCTAssertFalse(vm.isRunning, "失敗後は isRunning = false に戻ること")
    }
}
