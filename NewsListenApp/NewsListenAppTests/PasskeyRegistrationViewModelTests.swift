import XCTest
@testable import NewsListenApp

/// PasskeyRegistrationViewModel のテスト（AC ★コア）。
/// 仕様: register/options 取得 → provider.createCredential → register/verify → onSuccess の正常系と各異常系。
@MainActor
final class PasskeyRegistrationViewModelTests: XCTestCase {

    // MARK: - Fixtures

    /// バックエンドが返す登録 options の内側 JSON 文字列（python-webauthn 形式）。
    /// dict→JSON シリアライズで生成することで multiline string の indent 問題を回避する。
    private func makeInnerRegistrationOptionsJSON() -> String {
        let inner: [String: Any] = [
            "rp": ["id": "rp.example.com", "name": "News Listen"],
            "user": ["id": "dXNlcklE", "name": "alice", "displayName": "Alice"],
            "challenge": "Y2hhbGxlbmdl",
            "pubKeyCredParams": [["type": "public-key", "alg": -7]],
            "timeout": 60000,
            "excludeCredentials": [],
            "attestation": "none",
            "authenticatorSelection": [
                "residentKey": "required",
                "requireResidentKey": true,
                "userVerification": "required"
            ]
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: inner), encoding: .utf8)!
    }

    /// POST /auth/passkey/register/options レスポンス JSON。
    private var optionsResponseData: Data {
        let outer: [String: Any] = ["challenge_id": "chal-reg-1", "options": makeInnerRegistrationOptionsJSON()]
        return try! JSONSerialization.data(withJSONObject: outer)
    }

    /// POST /auth/passkey/register/verify 成功レスポンス。
    private let verifySuccessData = #"{"status":"ok"}"#.data(using: .utf8)!

    /// 正常系のシーケンシャルセッション（options → verify の2往復）。
    private var happyPathSession: SequentialMockSession {
        SequentialMockSession([
            .init(data: optionsResponseData, statusCode: 200),
            .init(data: verifySuccessData, statusCode: 200)
        ])
    }

    private func makeClient(session: URLSessionProtocol, token: String = "authed-tok") -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: token,
            session: session
        )
    }

    // MARK: - 正常系

    func testSuccessfulRegistrationCallsOnSuccess() async {
        let provider = MockPasskeyProvider()
        provider.createResult = .success(MockPasskeyProvider.makeRegistrationCredential())
        var successCalled = false

        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { successCalled = true }
        )

        await vm.register()

        XCTAssertTrue(successCalled, "登録成功時に onSuccess が呼ばれること")
        XCTAssertNil(vm.errorMessage, "正常系でエラーメッセージが表示されないこと")
    }

    func testSuccessfulRegistrationPassesCorrectOptionsToProvider() async {
        // provider が受け取った options がデコード結果と一致すること。
        let provider = MockPasskeyProvider()
        provider.createResult = .success(MockPasskeyProvider.makeRegistrationCredential())

        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: {}
        )

        await vm.register()

        XCTAssertEqual(
            provider.receivedRegistrationOptions?.challenge,
            Data("challenge".utf8),
            "Y2hhbGxlbmdl のデコード結果と一致すること"
        )
        XCTAssertEqual(provider.receivedRegistrationOptions?.rpID, "rp.example.com")
        XCTAssertEqual(provider.receivedRegistrationOptions?.userID, Data("userID".utf8),
                       "dXNlcklE のデコード結果と一致すること")
        XCTAssertEqual(provider.receivedRegistrationOptions?.userName, "alice")
        XCTAssertEqual(provider.createCallCount, 1)
    }

    // MARK: - 異常系: 409 Conflict（既登録）

    func testConflict409ShowsDedicatedMessage() async {
        // register/verify が 409 のとき、専用の「既登録」エラーメッセージが出ること。
        let provider = MockPasskeyProvider()
        provider.createResult = .success(MockPasskeyProvider.makeRegistrationCredential())
        var successCalled = false

        let conflictSession = SequentialMockSession([
            .init(data: optionsResponseData, statusCode: 200),
            .init(data: Data(), statusCode: 409)
        ])

        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: conflictSession),
            provider: provider,
            onSuccess: { successCalled = true }
        )

        await vm.register()

        XCTAssertFalse(successCalled)
        XCTAssertEqual(vm.errorMessage, "この Passkey はすでに登録されています")
    }

    // MARK: - 異常系: API 失敗

    func testAPIErrorSetsGenericErrorMessage() async {
        // register/options が 500 を返したとき汎用エラーが設定されること。
        let session = SequentialMockSession([.init(data: Data(), statusCode: 500)])
        let provider = MockPasskeyProvider()
        var successCalled = false

        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: session),
            provider: provider,
            onSuccess: { successCalled = true }
        )

        await vm.register()

        XCTAssertFalse(successCalled)
        XCTAssertNotNil(vm.errorMessage)
        // 409 専用メッセージではないこと。
        XCTAssertNotEqual(vm.errorMessage, "この Passkey はすでに登録されています")
    }

    // MARK: - 異常系: ユーザーキャンセル

    func testUserCancelDoesNotSetErrorMessage() async {
        let provider = MockPasskeyProvider()
        provider.createResult = .failure(PasskeyError.canceled)
        var successCalled = false

        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { successCalled = true }
        )

        await vm.register()

        XCTAssertFalse(successCalled)
        XCTAssertNil(vm.errorMessage, "キャンセルはエラー扱いしないため errorMessage は nil であること")
        XCTAssertFalse(vm.isRunning)
    }

    // MARK: - 異常系: provider 失敗

    func testProviderFailedSetsErrorMessage() async {
        struct FakeError: Error {}
        let provider = MockPasskeyProvider()
        provider.createResult = .failure(PasskeyError.failed(FakeError()))
        var successCalled = false

        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: happyPathSession),
            provider: provider,
            onSuccess: { successCalled = true }
        )

        await vm.register()

        XCTAssertFalse(successCalled)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - isRunning 状態管理

    func testIsRunningIsFalseAfterFailure() async {
        let session = SequentialMockSession([.init(data: Data(), statusCode: 500)])
        let vm = PasskeyRegistrationViewModel(
            apiClient: makeClient(session: session),
            provider: MockPasskeyProvider(),
            onSuccess: {}
        )

        await vm.register()

        XCTAssertFalse(vm.isRunning)
    }
}
