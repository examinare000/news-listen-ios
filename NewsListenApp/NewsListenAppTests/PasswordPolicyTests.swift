import XCTest
@testable import NewsListenApp

/// パスワードの長さ規則（domain）のテスト。他の層の型は参照しない。
final class PasswordPolicyTests: XCTestCase {

    /// 成功なら `nil`、違反なら違反の値。`Result<Void, _>` は `Equatable` でないため値に写して比べる。
    private func violation(of password: String) -> PasswordPolicyViolation? {
        if case .failure(let violation) = PasswordPolicy.validate(password) { return violation }
        return nil
    }

    // verifies: ios-contract-22
    func testIosTest101_lengthBoundaries11_12_20_21() {
        let cases: [(length: Int, expected: PasswordPolicyViolation?)] = [
            (0, .tooShort(minimum: 12)),
            (11, .tooShort(minimum: 12)),
            (12, nil),
            (20, nil),
            (21, .tooLong(maximum: 20)),
        ]
        for (length, expected) in cases {
            XCTAssertEqual(violation(of: String(repeating: "a", count: length)), expected, "length \(length)")
        }
    }

    // verifies: ios-contract-22
    func testIosContract22_countsCharactersNotBytes() {
        XCTAssertNil(violation(of: String(repeating: "あ", count: 12)))
        XCTAssertEqual(violation(of: String(repeating: "あ", count: 21)), .tooLong(maximum: 20))
        XCTAssertEqual(violation(of: String(repeating: "あ", count: 11)), .tooShort(minimum: 12))
    }

    // verifies: ios-contract-22
    func testIosContract22_publicBoundsMatchViolationAssociatedValues() {
        XCTAssertEqual(PasswordPolicy.minLength, 12)
        XCTAssertEqual(PasswordPolicy.maxLength, 20)
        XCTAssertEqual(
            violation(of: String(repeating: "a", count: PasswordPolicy.minLength - 1)),
            .tooShort(minimum: PasswordPolicy.minLength)
        )
        XCTAssertEqual(
            violation(of: String(repeating: "a", count: PasswordPolicy.maxLength + 1)),
            .tooLong(maximum: PasswordPolicy.maxLength)
        )
    }
}
