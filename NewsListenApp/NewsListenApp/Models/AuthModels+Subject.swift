//
//  AuthModels+Subject.swift
//  NewsListenApp
//
//  通信のデータモデル `AuthUser` から domain の `Subject` への変換（adapter）。
//

import Foundation

extension AuthUser {
    /// `key` は ios-slice-departure-01 で主体キーを受け取るまで `nil`。
    func toSubject() -> Subject {
        Subject(username: username, displayName: displayName, role: Role(rawValue: role), key: nil)
    }
}
