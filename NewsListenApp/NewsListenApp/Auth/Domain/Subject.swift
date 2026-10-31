//
//  Subject.swift
//  NewsListenApp
//
//  Account の domain の値（主体・ロール・主体キー）。通信のデータモデルは知らない。
//

import Foundation

/// 主体のロール。サーバーが返す値をそのまま保ち、未知の値も落とさない（ios-deriv-38。enum にしない）。
struct Role: Equatable {
    let rawValue: String

    static let admin = Role(rawValue: "admin")
    static let user = Role(rawValue: "user")

    /// 管理者かどうか。判定の式はここだけに置く（ios-rule-account-05）。
    var isAdmin: Bool { self == .admin }
}

/// 主体キー。`^[A-Za-z0-9_-]+$` に全体一致する文字列だけが作れる（ios-rule-account-04）。
struct SubjectKey: Equatable {
    let rawValue: String

    /// `nil`・空・形式外は `nil`。一致範囲が全体であることまで比べ、末尾改行を許さない。
    init?(_ raw: String?) {
        guard let raw,
              let range = raw.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression),
              range == raw.startIndex..<raw.endIndex
        else { return nil }
        self.rawValue = raw
    }
}

/// ログイン中の主体。`key` は ios-slice-departure-01 まで常に `nil`。
struct Subject: Equatable {
    let username: String
    let displayName: String
    let role: Role
    let key: SubjectKey?
}
