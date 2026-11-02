import XCTest
@testable import NewsListenApp

/// 取り消しの戻し位置・生成上限の待ち・残り回数を持つ domain の値型（`PendingCuration`・`GenerationLimitWait`・
/// `GenerationAllowance`）のテスト。domain だけを参照する（ios-check-08 の対象）。
final class CurationDomainTests: XCTestCase {

    // MARK: - PendingCuration.restore（ios-test-040）

    // verifies: ios-rule-curation-01
    func testRestoreInsertsAtOriginalIndexClampedToEnd() {
        let list = [1, 2, 3]
        let expectations: [(index: Int, expected: [Int])] = [
            (0, [9, 1, 2, 3]),
            (1, [1, 9, 2, 3]),
            (3, [1, 2, 3, 9]),
            (10, [1, 2, 3, 9]),   // 範囲外は末尾
        ]
        for (index, expected) in expectations {
            let pending = PendingCuration(kind: .dismiss, articleId: "x", originalIndex: index)
            XCTAssertEqual(pending.restore(9, into: list), expected, "originalIndex \(index)")
        }
    }

    // verifies: ios-rule-curation-01
    func testRestoreIntoEmptyListYieldsSingleElement() {
        let pending = PendingCuration(kind: .star(nil), articleId: "x", originalIndex: 4)

        XCTAssertEqual(pending.restore(9, into: [Int]()), [9])
    }

    // MARK: - GenerationLimitWait（ios-test-123）

    // verifies: ios-rule-curation-02
    func testGenerationLimitWaitRoundsUpAtBoundaries() {
        let cases: [(seconds: Int?, expected: GenerationLimitWait?)] = [
            (nil, nil),
            (0, nil),
            (-1, nil),
            (1, .soon),
            (59, .soon),
            (60, .minutes(1)),
            (61, .minutes(2)),
            (3540, .minutes(59)),
            (3541, .hours(1)),
            (3600, .hours(1)),
            (3601, .hours(2)),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(
                GenerationLimitWait(retryAfterSeconds: seconds),
                expected,
                "retryAfterSeconds \(String(describing: seconds))"
            )
        }
    }

    // MARK: - GenerationAllowance（ios-test-124）

    // verifies: ios-rule-curation-03
    func testGenerationAllowanceZeroLimitIsUnlimited() {
        let allowance = GenerationAllowance(limit: 0, used: 0, remaining: nil)

        XCTAssertEqual(allowance?.isUnlimited, true)
    }

    // verifies: ios-rule-curation-03
    func testGenerationAllowanceKeepsValuesAndIsNotUnlimitedWhenLimitPositive() {
        let allowance = GenerationAllowance(limit: 5, used: 2, remaining: 3)

        XCTAssertEqual(allowance?.limit, 5)
        XCTAssertEqual(allowance?.used, 2)
        XCTAssertEqual(allowance?.remaining, 3)
        XCTAssertEqual(allowance?.isUnlimited, false)
    }

    // verifies: ios-rule-curation-03
    func testGenerationAllowanceRejectsNegativeLimitOrUsed() {
        XCTAssertNil(GenerationAllowance(limit: -1, used: 0, remaining: nil))
        XCTAssertNil(GenerationAllowance(limit: 5, used: -1, remaining: 3))
    }
}
