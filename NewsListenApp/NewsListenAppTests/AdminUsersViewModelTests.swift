import XCTest
@testable import NewsListenApp

/// AdminUsersViewModel の操作（作成の入力検査、ロール切替・削除・取り直しの送信）のテスト。
@MainActor
final class AdminUsersViewModelTests: XCTestCase {

    private let lengthMessage = "ユーザーIDと12〜20文字のパスワードを入力してください"
    private let createdJSON = #"{"username":"bob","role":"user","display_name":"Bob","users":[]}"#

    private func makeClient(session: URLSessionProtocol) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
    }

    private func makeViewModel(client: @escaping @MainActor () -> APIClient?) -> AdminUsersViewModel {
        AdminUsersViewModel(administration: UserAdministration(gateway: .live(client: client), currentUsername: { nil }))
    }

    private func makeViewModel(session: URLSessionProtocol) -> AdminUsersViewModel {
        let client = makeClient(session: session)
        return makeViewModel(client: { client })
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
    func testIosContract22_createWithoutClientShowsFailure() async {
        let vm = makeViewModel(client: { nil })
        let valid = password(length: 12)
        fillForm(vm, username: "bob", password: valid)

        await vm.create()

        XCTAssertEqual(vm.errorMessage, "ユーザー作成に失敗しました（既に存在する可能性があります）")
        assertFormUntouched(vm, username: "bob", password: valid)
    }

    // verifies: ios-contract-22
    func testIosContract22_createWithEmptyUsernameShowsMessageWithoutRequest() async {
        let session = MockURLSession(data: Data(createdJSON.utf8), statusCode: 200)
        let vm = makeViewModel(session: session)
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
            let vm = makeViewModel(session: session)
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
            let vm = makeViewModel(session: session)
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

    // MARK: - 一覧・ロール切替・削除・作成の送信

    private let usersJSON = #"{"users":[{"username":"bob","role":"user","display_name":"Bob"},{"username":"carol","role":"admin","display_name":"Carol"}]}"#
    private let userJSON = #"{"username":"x","role":"user","display_name":"X"}"#

    private func sent(_ session: ScriptedURLSession) -> [String] {
        session.sentRequests.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "?")" }
    }

    private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // verifies: ios-rule-account-05
    func testIosRuleAccount05_toggleRoleAndDeleteSendOppositeRoleAndReloadEachTime() async throws {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: "/admin/users", status: 200, body: Data(usersJSON.utf8))
        session.configure(method: "PATCH", path: "/admin/users/bob", status: 200, body: Data(userJSON.utf8))
        session.configure(method: "PATCH", path: "/admin/users/carol", status: 200, body: Data(userJSON.utf8))
        let vm = makeViewModel(session: session)
        await vm.load()
        let bob = try XCTUnwrap(vm.users.first { $0.username == "bob" })
        let carol = try XCTUnwrap(vm.users.first { $0.username == "carol" })

        await vm.toggleRole(bob)
        await vm.toggleRole(carol)
        await vm.delete(username: "bob")

        XCTAssertEqual(sent(session), [
            "GET /admin/users",
            "PATCH /admin/users/bob", "GET /admin/users",
            "PATCH /admin/users/carol", "GET /admin/users",
            "DELETE /admin/users/bob", "GET /admin/users",
        ])
        let patches = session.sentRequests.filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(try jsonBody(patches[0])["role"] as? String, "admin", "user の bob は admin へ")
        XCTAssertEqual(try jsonBody(patches[1])["role"] as? String, "user", "admin の carol は user へ")
        XCTAssertNil(vm.errorMessage)
    }

    // verifies: ios-rule-account-05
    func testIosRuleAccount05_createSendsDraftValuesResetsDraftAndReloads() async throws {
        let session = ScriptedURLSession()
        session.configure(method: "POST", path: "/admin/users", status: 200, body: Data(userJSON.utf8))
        session.configure(method: "GET", path: "/admin/users", status: 200, body: Data(usersJSON.utf8))
        let vm = makeViewModel(session: session)
        XCTAssertEqual(vm.newRole, "user", "初期値")
        vm.newUsername = "dave"
        vm.newPassword = password(length: 12)
        vm.newDisplayName = "Dave"
        vm.newRole = "admin"

        await vm.create()

        let post = try XCTUnwrap(session.sentRequests.first { $0.httpMethod == "POST" })
        let body = try jsonBody(post)
        XCTAssertEqual(body["username"] as? String, "dave")
        XCTAssertEqual(body["password"] as? String, password(length: 12))
        XCTAssertEqual(body["display_name"] as? String, "Dave")
        XCTAssertEqual(body["role"] as? String, "admin")
        XCTAssertEqual(sent(session), ["POST /admin/users", "GET /admin/users"])
        XCTAssertEqual(vm.newUsername, "")
        XCTAssertEqual(vm.newPassword, "")
        XCTAssertEqual(vm.newDisplayName, "")
        XCTAssertEqual(vm.newRole, "user")
        XCTAssertEqual(vm.users.count, 2)
    }

    // verifies: ios-rule-account-05
    func testIosRuleAccount05_loadFailureKeepsUsersAndNextLoadClearsMessage() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: "/admin/users", status: 200, body: Data(usersJSON.utf8))
        let vm = makeViewModel(session: session)

        await vm.load()
        XCTAssertEqual(vm.users.map(\.username), ["bob", "carol"])

        session.configure(method: "GET", path: "/admin/users", status: 500)
        await vm.load()

        XCTAssertEqual(vm.users.map(\.username), ["bob", "carol"], "取り直しの失敗で一覧を空にしない")
        XCTAssertEqual(vm.errorMessage, "ユーザー一覧の取得に失敗しました")

        session.configure(method: "GET", path: "/admin/users", status: 200, body: Data(usersJSON.utf8))
        await vm.load()

        XCTAssertNil(vm.errorMessage, "成功した取得で前回の文言が消える")
    }
}
