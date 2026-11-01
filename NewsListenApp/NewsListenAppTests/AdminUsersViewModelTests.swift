import XCTest
@testable import NewsListenApp

/// AdminUsersViewModel.create() の入力検査（クライアントの有無 → ユーザーID → パスワードの長さ）のテスト。
@MainActor
final class AdminUsersViewModelTests: XCTestCase {

    private let lengthMessage = "ユーザーIDと12〜20文字のパスワードを入力してください"
    private let createdJSON = #"{"username":"bob","role":"user","display_name":"Bob","users":[]}"#

    private func makeClient(session: MockURLSession) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
    }

    private func password(length: Int) -> String {
        String(repeating: "a", count: length)
    }

    private func fillForm(_ vm: AdminUsersViewModel, username: String, password: String) {
        vm.newUsername = username
        vm.newPassword = password
        vm.newDisplayName = "Bob"
        vm.newRole = "admin"
    }

    private func assertFormUntouched(_ vm: AdminUsersViewModel, username: String, password: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(vm.newUsername, username, file: file, line: line)
        XCTAssertEqual(vm.newPassword, password, file: file, line: line)
        XCTAssertEqual(vm.newDisplayName, "Bob", file: file, line: line)
        XCTAssertEqual(vm.newRole, "admin", file: file, line: line)
    }

    // verifies: ios-contract-22
    func testIosContract22_createWithoutClientDoesNothing() async {
        let vm = AdminUsersViewModel(apiClient: nil)
        fillForm(vm, username: "", password: "x")

        await vm.create()

        XCTAssertNil(vm.errorMessage, "client が無いときは検査より先に何もせず戻る")
        assertFormUntouched(vm, username: "", password: "x")
    }

    // verifies: ios-contract-22
    func testIosContract22_createWithEmptyUsernameShowsMessageWithoutRequest() async {
        let session = MockURLSession(data: Data(createdJSON.utf8), statusCode: 200)
        let vm = AdminUsersViewModel(apiClient: makeClient(session: session))
        let valid = password(length: 12)
        fillForm(vm, username: "", password: valid)

        await vm.create()

        XCTAssertEqual(vm.errorMessage, lengthMessage)
        XCTAssertNil(session.lastRequest)
        assertFormUntouched(vm, username: "", password: valid)
    }

    // verifies: ios-contract-22
    func testIosContract22_createRejectsPasswordsOutsideRangeWithoutRequest() async {
        for length in [7, 8, 11, 21] {
            let session = MockURLSession(data: Data(createdJSON.utf8), statusCode: 200)
            let vm = AdminUsersViewModel(apiClient: makeClient(session: session))
            let candidate = password(length: length)
            fillForm(vm, username: "bob", password: candidate)

            await vm.create()

            XCTAssertEqual(vm.errorMessage, lengthMessage, "length \(length)")
            XCTAssertNil(session.lastRequest, "length \(length) は通信しない")
            assertFormUntouched(vm, username: "bob", password: candidate)
        }
    }

    // verifies: ios-contract-22
    func testIosContract22_createAcceptsPasswordsAtBoundaries() async {
        for length in [12, 20] {
            let session = MockURLSession(data: Data(createdJSON.utf8), statusCode: 200)
            let vm = AdminUsersViewModel(apiClient: makeClient(session: session))
            fillForm(vm, username: "bob", password: password(length: length))

            await vm.create()

            XCTAssertNil(vm.errorMessage, "length \(length)")
            XCTAssertNotNil(session.lastRequest, "length \(length) は作成の通信をする")
            XCTAssertEqual(vm.newUsername, "", "length \(length)")
            XCTAssertEqual(vm.newPassword, "", "length \(length)")
            XCTAssertEqual(vm.newDisplayName, "", "length \(length)")
            XCTAssertEqual(vm.newRole, "user", "length \(length)")
        }
    }
}
