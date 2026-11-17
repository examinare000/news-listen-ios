import XCTest
@testable import NewsListenApp

/// 再開の確認の文言・書式（`ResumeChoicePrompt`）と、View がそれを読むだけの配線であることのテスト。
final class ResumeChoicePromptTests: XCTestCase {

    // verifies: shared-sync-14, shared-dec-42
    // kills: 見出しの文言変更／ボタンの並びの入れ替え／ボタンのラベルへの位置の付与／本文の区切りや秒の入れ替え
    func testPromptShowsTheAgreedTitleMessageAndTwoButtonsInOrder() {
        XCTAssertEqual(ResumeChoicePrompt.title, "どちらの位置から続けますか")

        let options = ResumeChoicePrompt.options
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.map(\.selection), [.otherDevice, .thisDevice])
        XCTAssertEqual(options.map(\.label), ["別の端末の位置から", "この端末の位置から"])
        XCTAssertEqual(Set(options.map(\.id)).count, 2, "id は互いに異なる")

        // 65 と 760 は非対称なので、2 つの秒の入れ替えが見える。
        XCTAssertEqual(
            ResumeChoicePrompt.message(otherDeviceSeconds: 65, thisDeviceSeconds: 760),
            "別の端末: 1:05 ／ この端末: 12:40")
    }

    // verifies: shared-sync-14, shared-dec-42
    // kills: 秒を 0 埋めしない／切り捨てを四捨五入にする／分を時間へ繰り上げる／負の値をそのまま出す
    func testClockFormatsMinutesAndTwoDigitSeconds() {
        let cases: [(seconds: Double, expected: String)] = [
            (0, "0:00"),
            (5, "0:05"),
            (59.9, "0:59"),
            (60, "1:00"),
            (65, "1:05"),
            (760, "12:40"),
            (3599.99, "59:59"),
            (3600, "60:00"),
            (-3, "0:00"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(ResumeChoicePrompt.clock(seconds), expected, "seconds = \(seconds)")
        }
    }

    // verifies: shared-sync-14, shared-dec-42
    // kills: View へ文言を書き戻す／ボタンの並びの反転／本文の引数の入れ替え／選択の固定／ラベルの差し替え／
    //        titleVisibility の変更／閉じ方の同期化／ResumeChoicePrompt が SwiftUI を import する
    func testResumeChoiceViewHoldsNoWordingOfItsOwn() {
        let view = SourceGrep.content(of: SourceGrep.appRoot.appendingPathComponent("Podcast/ResumeChoiceView.swift"))
        let prompt = SourceGrep.content(
            of: SourceGrep.appRoot.appendingPathComponent("Shared/Presentation/ResumeChoicePrompt.swift"))
        XCTAssertFalse(view.isEmpty, "View のソースを読めない（検査が空振りになる）")
        XCTAssertFalse(prompt.isEmpty, "ResumeChoicePrompt のソースを読めない（検査が空振りになる）")

        let viewCodeLines = view.components(separatedBy: "\n").filter { !SourceGrep.isCommentLine($0) }
        XCTAssertEqual(viewCodeLines.filter { $0.contains("\"") }, [], "View に文字列リテラルがある")
        XCTAssertEqual(viewCodeLines.filter { $0.contains("%d") }, [], "View に書式がある")

        // 空白を除いて比べる: 整形の違いには左右されず、並び・引数・選択・閉じ方の配線だけが固定される。
        let wiring = viewCodeLines.joined().components(separatedBy: .whitespacesAndNewlines).joined()
        let fragments = [
            "confirmationDialog(ResumeChoicePrompt.title,isPresented:isPresented,titleVisibility:.visible,presenting:vm.resumeChoice)",
            "ForEach(ResumeChoicePrompt.options){optionin",
            "Button(option.label){vm.resolveResume(option.selection)}",
            "Text(ResumeChoicePrompt.message(otherDeviceSeconds:choice.otherDeviceSeconds,thisDeviceSeconds:choice.thisDeviceSeconds))",
            "DispatchQueue.main.async{vm.resolveResume(nil)}",
        ]
        for fragment in fragments {
            XCTAssertEqual(Self.occurrences(of: fragment, in: wiring), 1, "View の配線に次の断片が 1 回だけ無い: \(fragment)")
        }
        XCTAssertEqual(Self.occurrences(of: "ResumeChoicePrompt.", in: wiring), 3, "ResumeChoicePrompt の参照は見出し・ボタン・本文の 3 回")
        XCTAssertEqual(Self.occurrences(of: "resolveResume(", in: wiring), 2, "resolveResume の呼びはボタンと閉じ方の 2 回")

        let importsSwiftUI = prompt.components(separatedBy: "\n").filter { $0.hasPrefix("import SwiftUI") }
        XCTAssertEqual(importsSwiftUI, [], "ResumeChoicePrompt は SwiftUI に依存しない")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
