//
//  LicenseNotice.swift
//  NewsListenApp
//
//  CC BY-SA の帰属表示の文言（ADR-095）。`Podcast`（DTO）の static ではなく、表示の層が持つ。
//

import Foundation

enum LicenseNotice {
    /// web `page.tsx` と同一文言の Markdown ソース。リンク範囲は "CC BY-SA 4.0" のみ（issue #240）。
    static let ccBySaLicenseNoticeMarkdown =
        "この音声コンテンツは [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.ja) で提供されます。"
    /// Markdown 除去後の表示文字列（テストと Markdown 解析失敗時のフォールバックで共有）。
    static let ccBySaLicenseNoticePlainText = "この音声コンテンツは CC BY-SA 4.0 で提供されます。"
    /// `Text(_: AttributedString)` に渡す値。`.link` 属性を持つ run が "CC BY-SA 4.0" だけになる。
    static let ccBySaLicenseNotice: AttributedString = {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // WHY: 定数リテラルの解析失敗は起こらない前提だが、万一失敗してもプレイヤーを落とさず
        //      プレーン文で帰属表示を維持する。
        return (try? AttributedString(markdown: ccBySaLicenseNoticeMarkdown, options: options))
            ?? AttributedString(ccBySaLicenseNoticePlainText)
    }()
}
