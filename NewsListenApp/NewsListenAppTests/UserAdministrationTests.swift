import XCTest
@testable import NewsListenApp

/// `UserAdministration`（管理者のユーザー管理）の手順のテスト。自分の行の可否、長さの検査、失敗の包み方を固定する。
@MainActor
final class UserAdministrationTests: XCTestCase {

    private struct CreateCall: Equatable {
        let username: String
        let password: String
        let displayName: String?
        let role: Role
    }

    private final class CommandRecorder {
        var creates: [CreateCall] = []
        var setRoles: [(username: String, role: Role)] = []
        var deletes: [String] = []
        var currentUsername: String?
    }

    private let alice = Subject(username: "alice", displayName: "Alice Display", role: .admin, key: nil)
    private let bob = Subject(username: "bob", displayName: "Bob Display", role: .user, key: nil)

    private func password(length: Int) -> String {
        String(repeating: "p", count: length)
    }

    // verifies: ios-cmd-account-09, ios-rule-account-07, ios-test-006
    func testIosTest006_usersMarksOnlyCurrentUserAsNotChangeableAndMapsFields() async throws {
        let rows = [alice, bob]
        let sut = UserAdministration(gateway: .stub(listUsers: { rows }), currentUsername: { "alice" })

        let users = try await sut.users()

        XCTAssertEqual(users.map(\.username), ["alice", "bob"])
        XCTAssertEqual(users.map(\.displayName), ["Alice Display", "Bob Display"])
        XCTAssertEqual(users.map(\.role), [.admin, .user])
        XCTAssertEqual(users.map(\.canChangeRoleOrDelete), [false, true])
    }

    // verifies: ios-rule-account-07
    func testIosRuleAccount07_usersAllowsEveryoneWhenCurrentUserIsUnknown() async throws {
        let rows = [alice, bob]
        let sut = UserAdministration(gateway: .stub(listUsers: { rows }), currentUsername: { nil })

        let users = try await sut.users()

        XCTAssertEqual(users.map(\.canChangeRoleOrDelete), [true, true])
    }

    // verifies: ios-rule-account-07
    func testIosRuleAccount07_usersReadsCurrentUsernameOnEveryCall() async throws {
        let rows = [alice, bob]
        let recorder = CommandRecorder()
        recorder.currentUsername = "alice"
        let sut = UserAdministration(gateway: .stub(listUsers: { rows }), currentUsername: { recorder.currentUsername })

        let first = try await sut.users()
        recorder.currentUsername = "bob"
        let second = try await sut.users()

        XCTAssertEqual(first.map(\.canChangeRoleOrDelete), [false, true])
        XCTAssertEqual(second.map(\.canChangeRoleOrDelete), [true, false])
    }

    // verifies: ios-rule-account-05
    func testIosRuleAccount05_usersKeepsRowsWithUnknownRole() async throws {
        let unknown = Subject(username: "carol", displayName: "Carol", role: Role(rawValue: "x"), key: nil)
        let sut = UserAdministration(gateway: .stub(listUsers: { [unknown] }), currentUsername: { nil })

        let users = try await sut.users()

        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.role, Role(rawValue: "x"))
    }

    // verifies: ios-query-account-02
    func testIosQueryAccount02_usersRethrowsApiFailureWithoutWrapping() async {
        let sut = UserAdministration(gateway: .stub(listUsers: { throw ApiFailure.server(status: 500) }), currentUsername: { nil })

        do {
            _ = try await sut.users()
            XCTFail("失敗は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    // verifies: ios-cmd-account-09
    func testIosCmdAccount09_createRejectsOutOfRangePasswordsWithoutCallingGateway() async {
        let expectations: [(length: Int, violation: PasswordPolicyViolation)] = [
            (11, .tooShort(minimum: 12)),
            (21, .tooLong(maximum: 20)),
        ]
        for (length, violation) in expectations {
            let sut = UserAdministration(gateway: .stub(), currentUsername: { nil })

            do {
                try await sut.create(username: "bob", password: password(length: length), displayName: "", role: .user)
                XCTFail("length \(length) は拒否される")
            } catch {
                XCTAssertEqual(error as? UserAdministrationFailure, .policyViolation(violation), "length \(length)")
            }
        }
    }

    // verifies: ios-cmd-account-09
    func testIosCmdAccount09_createForwardsArgumentsInGatewayOrderAndMapsEmptyDisplayNameToNil() async throws {
        let recorder = CommandRecorder()
        let gateway = AccountGateway.stub(createUser: { username, password, displayName, role in
            recorder.creates.append(CreateCall(username: username, password: password, displayName: displayName, role: role))
        })
        let sut = UserAdministration(gateway: gateway, currentUsername: { nil })
        let pw = password(length: 12)

        try await sut.create(username: "bob", password: pw, displayName: "", role: .admin)
        try await sut.create(username: "bob", password: pw, displayName: "Bob", role: .admin)
        try await sut.create(username: "", password: pw, displayName: "", role: .user)

        XCTAssertEqual(recorder.creates, [
            CreateCall(username: "bob", password: pw, displayName: nil, role: .admin),
            CreateCall(username: "bob", password: pw, displayName: "Bob", role: .admin),
            CreateCall(username: "", password: pw, displayName: nil, role: .user),
        ])
    }

    // verifies: ios-cmd-account-09
    func testIosCmdAccount09_commandsWrapApiFailureAsApi() async {
        let sut = UserAdministration(
            gateway: .stub(
                createUser: { _, _, _, _ in throw ApiFailure.conflict },
                updateUserRole: { _, _ in throw ApiFailure.conflict },
                deleteUser: { _ in throw ApiFailure.conflict }
            ),
            currentUsername: { nil }
        )
        let operations: [(String, () async throws -> Void)] = [
            ("create", { try await sut.create(username: "bob", password: String(repeating: "p", count: 12), displayName: "", role: .user) }),
            ("setRole", { try await sut.setRole(username: "bob", role: .admin) }),
            ("delete", { try await sut.delete(username: "bob") }),
        ]

        for (label, operation) in operations {
            do {
                try await operation()
                XCTFail("\(label) は失敗する")
            } catch {
                XCTAssertEqual(error as? UserAdministrationFailure, .api(.conflict), label)
            }
        }
    }

    // verifies: ios-cmd-account-09
    func testIosCmdAccount09_setRoleAndDeleteForwardArgumentsAndReturnNothing() async throws {
        let recorder = CommandRecorder()
        let sut = UserAdministration(
            gateway: .stub(
                updateUserRole: { username, role in recorder.setRoles.append((username, role)) },
                deleteUser: { username in recorder.deletes.append(username) }
            ),
            currentUsername: { nil }
        )

        let _: Void = try await sut.setRole(username: "bob", role: .admin)
        let _: Void = try await sut.delete(username: "carol")

        XCTAssertEqual(recorder.setRoles.count, 1)
        XCTAssertEqual(recorder.setRoles.first?.username, "bob")
        XCTAssertEqual(recorder.setRoles.first?.role, .admin)
        XCTAssertEqual(recorder.deletes, ["carol"])
    }

    // verifies: ios-check-07, ios-test-108
    func testIosTest108_mutatingReturnedUsersDoesNotChangeNextUsers() async throws {
        let rows = [alice, bob]
        let sut = UserAdministration(gateway: .stub(listUsers: { rows }), currentUsername: { nil })

        var first = try await sut.users()
        first.removeAll()
        let second = try await sut.users()

        XCTAssertEqual(second.map(\.username), ["alice", "bob"])
    }
}
