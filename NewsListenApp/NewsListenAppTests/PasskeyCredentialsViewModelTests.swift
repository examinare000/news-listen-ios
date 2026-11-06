import XCTest
@testable import NewsListenApp

/// verifies: ios-contract-19（R-keep2）。`PasskeyCredentialsViewModel.deleteCredential(id:)` の既存分岐
/// （404 = 冪等成功／500 = 汎用エラー文言）を、`ApiFailure` への置換前後で固定する特性テスト。
@MainActor
final class PasskeyCredentialsViewModelTests: XCTestCase {

    private let listPath = "/auth/passkey/credentials"
    private let loadFailure = "クレデンシャル一覧の取得に失敗しました"

    private func makeClient(session: URLSessionProtocol) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
    }

    private func makeViewModel(session: URLSessionProtocol) -> PasskeyCredentialsViewModel {
        let client = makeClient(session: session)
        return PasskeyCredentialsViewModel(
            enrollment: PasskeyEnrollment(gateway: .live(client: { client }), provider: MockPasskeyProvider())
        )
    }

    private func credentialsJSON(_ ids: [String]) -> Data {
        let items = ids.map {
            #"{"credential_id":"\#($0)","username":"alice","name":"Key \#($0)","transports":["internal"],"sign_count":1,"created_at":"2026-01-01T00:00:00Z"}"#
        }
        return Data(#"{"credentials":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    func testDeleteCredential404IsTreatedAsIdempotentSuccess() async throws {
        let vm = makeViewModel(session: MockURLSession(data: Data(), statusCode: 404))

        await vm.deleteCredential(id: "c1")

        XCTAssertNil(vm.errorMessage)
    }

    func testDeleteCredential500SetsGenericErrorMessage() async throws {
        let vm = makeViewModel(session: MockURLSession(data: Data(), statusCode: 500))

        await vm.deleteCredential(id: "c1")

        XCTAssertEqual(vm.errorMessage, "Passkey の削除に失敗しました")
    }

    // verifies: ios-rule-account-06
    func testDeleteCredential404RemovesRowAndKeepsMessageNil() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: listPath, status: 200, body: credentialsJSON(["c1", "c2"]))
        session.configure(method: "DELETE", path: "/auth/passkey/credentials/c1", status: 404)
        let vm = makeViewModel(session: session)
        await vm.loadCredentials()
        XCTAssertEqual(vm.credentials.map(\.id), ["c1", "c2"])

        await vm.deleteCredential(id: "c1")

        XCTAssertEqual(vm.credentials.map(\.id), ["c2"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // verifies: ios-rule-account-06
    func testDeleteCredential500KeepsRowAndShowsMessage() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: listPath, status: 200, body: credentialsJSON(["c1", "c2"]))
        session.configure(method: "DELETE", path: "/auth/passkey/credentials/c1", status: 500)
        let vm = makeViewModel(session: session)
        await vm.loadCredentials()

        await vm.deleteCredential(id: "c1")

        XCTAssertEqual(vm.credentials.map(\.id), ["c1", "c2"])
        XCTAssertEqual(vm.errorMessage, "Passkey の削除に失敗しました")
        XCTAssertFalse(vm.isLoading)
    }

    // verifies: ios-rule-account-06
    func testLoadFailureKeepsRowsAndNextLoadReplacesThemAndClearsMessage() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: listPath, status: 200, body: credentialsJSON(["c1", "c2"]))
        let vm = makeViewModel(session: session)

        await vm.loadCredentials()
        XCTAssertEqual(vm.credentials.map(\.id), ["c1", "c2"])
        XCTAssertFalse(vm.isLoading)

        session.configure(method: "GET", path: listPath, status: 500)
        await vm.loadCredentials()

        XCTAssertEqual(vm.credentials.map(\.id), ["c1", "c2"], "取り直しの失敗で一覧を空にしない")
        XCTAssertEqual(vm.errorMessage, loadFailure)
        XCTAssertFalse(vm.isLoading)

        session.configure(method: "GET", path: listPath, status: 200, body: credentialsJSON(["c3"]))
        await vm.loadCredentials()

        XCTAssertEqual(vm.credentials.map(\.id), ["c3"])
        XCTAssertNil(vm.errorMessage, "再実行の開始で前回の文言が消える")
        XCTAssertFalse(vm.isLoading)
    }
}
