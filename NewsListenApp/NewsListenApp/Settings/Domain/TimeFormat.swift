//
//  TimeFormat.swift
//  NewsListenApp
//
//  記事の日付表記方式の値域と既定値の正本（ios-rule-prefs-03）。
//

import Foundation

/// 日付表記方式。`"absolute"` と `"relative"` の literal を持つ唯一のファイル。
struct TimeFormat: Equatable, Hashable {
    let rawValue: String

    /// `"absolute"`・`"relative"` だけ。
    init?(rawValue: String) {
        guard let format = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = format
    }

    private init(checked rawValue: String) {
        self.rawValue = rawValue
    }

    static let absolute = TimeFormat(checked: "absolute")
    static let relative = TimeFormat(checked: "relative")

    static let allCases: [TimeFormat] = [absolute, relative]

    static let `default`: TimeFormat = absolute
}
