import XCTest
@testable import NewsListenApp

/// 再開時の確認が要るかの判定（domain）。domain の型だけを使う。
final class ResumeConfirmationTests: XCTestCase {

    // verifies: ios-rule-playback-10, shared-sync-10
    // kills: 閾値の比較を > にする／別の端末が戻した場合（差が負）を尋ねない／差の絶対値を取らない／閾値を取り違える
    func testChoiceIsReturnedFromFifteenSecondsInEitherDirectionAndNotBelow() {
        let thisDevice = 100.0
        let cases: [(other: Double, asks: Bool, why: String)] = [
            (114.999, false, "15 秒未満（進めた側）"),
            (115, true, "ちょうど 15 秒（進めた側）は出す"),
            (115.001, true, "15 秒を超える（進めた側）"),
            (85, true, "ちょうど 15 秒（戻した側）は出す"),
            (85.001, false, "15 秒未満（戻した側）"),
        ]
        for (other, asks, why) in cases {
            let choice = ResumeConfirmation.choice(
                episodeId: "e", thisDeviceSeconds: thisDevice, otherDeviceSeconds: other)
            if asks {
                XCTAssertEqual(
                    choice,
                    ResumeChoice(episodeId: "e", thisDeviceSeconds: thisDevice, otherDeviceSeconds: other),
                    "\(why): 3 つの値を入力のまま持つ")
            } else {
                XCTAssertNil(choice, why)
            }
        }
    }
}
