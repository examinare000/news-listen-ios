//
//  AuthModels+Subject.swift
//  NewsListenApp
//
//  通信のデータモデル `AuthUser` から domain の `Subject` への変換（adapter）。
//

import Foundation

extension AuthUser {
    /// `key` は `userId` が主体キーの形式を満たすときだけ入る。欠落・形式外は `nil`。
    func toSubject() -> Subject {
        Subject(username: username, displayName: displayName, role: Role(rawValue: role), key: SubjectKey(userId))
    }
}
