import XCTest
@testable import NewsListenApp

/// Account の domain の値（`Role`・`SubjectKey`）のテスト。通信のデータモデルは参照しない。
final class SubjectTests: XCTestCase {

    // verifies: ios-rule-account-05
    func testIosTest036_roleIsAdminOnlyForExactAdminAndKeepsRawValue() {
        for (raw, expectedAdmin) in [("admin", true), ("user", false), ("ADMIN", false), ("owner", false)] {
            let role = Role(rawValue: raw)

            XCTAssertEqual(role.isAdmin, expectedAdmin, raw)
            XCTAssertEqual(role.rawValue, raw, raw)
        }
    }

    // verifies: ios-rule-account-05
    func testRoleAdminAndUserConstantsHoldTheirRawValues() {
        XCTAssertEqual(Role.admin.rawValue, "admin")
        XCTAssertEqual(Role.user.rawValue, "user")
        XCTAssertTrue(Role.admin.isAdmin)
        XCTAssertFalse(Role.user.isAdmin)
        XCTAssertEqual(Role(rawValue: "admin"), .admin)
    }

    // verifies: ios-rule-account-04
    func testIosTest035_subjectKeyAcceptsOnlyAllowedCharacters() {
        XCTAssertEqual(SubjectKey("abc_-1")?.rawValue, "abc_-1")

        let rejected: [String?] = [nil, "", "a b", "日本", "a/b", "abc\n"]
        for raw in rejected {
            XCTAssertNil(SubjectKey(raw), "\(String(describing: raw))")
        }
    }
}
