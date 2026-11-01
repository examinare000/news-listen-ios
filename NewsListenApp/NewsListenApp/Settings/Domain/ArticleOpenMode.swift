//
//  ArticleOpenMode.swift
//  NewsListenApp
//
//  記事タップ時の遷移先（アプリ内 Safari か外部 Safari。要件 §3.2/§3.6・AC-5）。
//

import Foundation

/// 記事タップ時の遷移先。値・label・表示順は `AppState.swift` にあった enum から変えない。
struct ArticleOpenMode: Equatable, Hashable, Identifiable {
    let rawValue: String

    /// `"in_app"`・`"external"` だけ。
    init?(rawValue: String) {
        guard let mode = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = mode
    }

    private init(checked rawValue: String) {
        self.rawValue = rawValue
    }

    /// アプリ内 Safari（`SFSafariViewController`）で開く。
    static let inApp = ArticleOpenMode(checked: "in_app")
    /// 外部 Safari アプリで開く。
    static let external = ArticleOpenMode(checked: "external")

    /// `ForEach` が使う表示順。
    static let allCases: [ArticleOpenMode] = [inApp, external]

    /// `ForEach` 等で利用する一意な識別子（rawValue を流用）。
    var id: String { rawValue }

    /// 設定画面の Picker に表示する日本語ラベル。
    var label: String {
        self == .inApp ? "アプリ内 Safari" : "外部 Safari"
    }
}
