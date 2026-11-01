//
//  AuthModels.swift
//  NewsListenApp
//
//  ログイン認証・ユーザー管理に関するモデル。snake_case な API レスポンスとの
//  マッピングは各 CodingKeys で行う（プロジェクト共通方針）。
//

import Foundation

/// ログイン中ユーザーの公開情報（GET /auth/me 等）。`password_hash` は含まれない。
struct AuthUser: Codable, Identifiable, Equatable {
    /// ログイン ID 兼一意キー。
    let username: String
    /// 権限ロール（"admin" / "user"）。
    let role: String
    /// アプリ内で表示する名前。
    let displayName: String
    /// 主体キー（サーバーが返す `user_id`）。欠落していてもログインは成立させる。
    let userId: String?

    /// `Identifiable` 準拠。username を一意キーに使う。
    var id: String { username }

    /// snake_case な API レスポンスとのマッピング。
    enum CodingKeys: String, CodingKey {
        case username
        case role
        case displayName = "display_name"
        case userId = "user_id"
    }
}

/// POST /auth/login のレスポンス。
///
/// `token` は Cookie を使わない iOS クライアント向けに `Authorization: Bearer` で送る。
struct LoginResponse: Codable {
    /// セッショントークン（Keychain に保存する）。
    let token: String
    /// ログインしたユーザー情報。
    let user: AuthUser
}

/// GET /admin/users のレスポンス。
struct UserListResponse: Codable {
    /// 登録済みユーザー一覧。
    let users: [AuthUser]
}
