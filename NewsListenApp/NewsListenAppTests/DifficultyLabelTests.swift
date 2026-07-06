import XCTest
@testable import NewsListenApp

/// issue #163: 記事単位の難易度指定 star の contextMenu で全難易度を列挙するための一覧。
final class DifficultyLabelTests: XCTestCase {

    func testAllCodesListsSixDifficultiesInDisplayOrder() {
        XCTAssertEqual(
            DifficultyLabel.allCodes,
            ["toeic_600", "toeic_900", "ielts_55", "ielts_7", "eiken_2", "eiken_p1"]
        )
    }

    func testAllCodesAreAllResolvableToNonDefaultLabels() {
        // text(for:) の default 分岐（未知値はそのまま返す）に落ちていないことを保証する。
        for code in DifficultyLabel.allCodes {
            XCTAssertNotEqual(DifficultyLabel.text(for: code), code)
        }
    }
}
