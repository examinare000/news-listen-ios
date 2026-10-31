//
//  AuthSession.swift
//  NewsListenApp
//
//  認証状態の判別共用体。
//

import Foundation

/// 認証状態（ios-slice-auth-01）。判別共用体で 4 状態のみを表す。
enum AuthSession: Equatable {
    /// 保存済みトークンで `/auth/me` を解決中（初期値）。
    case resolving
    /// ログイン済み。
    case authenticated(Subject)
    /// 未ログイン（トークン無し、または `fetchMe` が `unauthorized`）。
    case anonymous
    /// `/auth/me` が `unauthorized` 以外の理由で失敗（トークンは保持）。
    case unavailable(ApiFailure)
}
