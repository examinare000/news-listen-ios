//
//  APIEndpoint.swift
//  NewsListenApp
//
//  バックエンド API のエンドポイント定義（パスと HTTP メソッド）。
//

import Foundation

/// バックエンド API のエンドポイント定義。各ケースが URL パスと HTTP メソッドを表す。
enum APIEndpoint {
    /// フィード記事一覧の取得。
    case feed
    /// 記事を Star する。
    case starArticle(id: String)
    /// 記事を Dismiss する。
    case dismissArticle(id: String)
    /// Podcast 一覧の取得。
    case podcasts
    /// 指定 ID の Podcast を取得（署名付き audioUrl 再取得用）。
    case podcast(id: String)
    /// 登録済み RSS 配信元一覧の取得。
    case sources
    /// RSS 配信元の追加。
    case addSource
    /// 指定 URL の RSS 配信元の削除。
    case removeSource(url: String)
    /// システム提供のおすすめサイト一覧の取得。
    case featuredSources
    /// 初回オンボーディング完了状態の取得。
    case onboardingStatus
    /// 初回オンボーディング完了の記録。
    case completeOnboarding

    // 認証・ユーザー管理
    /// ログイン（セッション発行）。
    case login
    /// ログアウト（セッション破棄）。
    case logout
    /// ログイン中ユーザー情報の取得。
    case me
    /// 自分のプロフィール（表示名）更新。
    case updateProfile
    /// 自分のパスワード変更。
    case changePassword
    /// ユーザー一覧の取得（管理者）。
    case listUsers
    /// ユーザーの新規作成（管理者）。
    case createUser
    /// ユーザーの更新（ロール/パスワード/表示名・管理者）。
    case updateUser(username: String)
    /// ユーザーの削除（管理者）。
    case deleteUser(username: String)

    // Passkey（WebAuthn）
    /// Passkey 登録オプションの取得（Bearer 要）。
    case passkeyRegisterOptions
    /// Passkey 登録の検証・保存（Bearer 要）。
    case passkeyRegisterVerify
    /// Passkey 認証オプションの取得（認証不要・CSRF 免除）。
    case passkeyLoginOptions
    /// Passkey 認証の検証・セッション発行（認証不要）。
    case passkeyLoginVerify
    /// 登録済み Passkey クレデンシャル一覧の取得（Bearer 要）。
    case passkeyCredentials
    /// 指定クレデンシャルの削除（Bearer 要・パス param は base64url 文字列）。
    case passkeyDeleteCredential(id: String)

    /// エンドポイントへの相対パス（baseURL に連結して使う）。
    var path: String {
        switch self {
        case .feed: return "/feed"
        case .starArticle(let id): return "/articles/\(id)/star"
        case .dismissArticle(let id): return "/articles/\(id)/dismiss"
        case .podcasts: return "/podcasts"
        case .podcast(let id): return "/podcasts/\(id)"
        case .sources, .addSource: return "/settings/sources"
        case .removeSource: return "/settings/sources"
        case .featuredSources: return "/settings/featured-sources"
        case .onboardingStatus: return "/settings/onboarding"
        case .completeOnboarding: return "/settings/onboarding/complete"
        case .login: return "/auth/login"
        case .logout: return "/auth/logout"
        case .me, .updateProfile: return "/auth/me"
        case .changePassword: return "/auth/password"
        case .listUsers, .createUser: return "/admin/users"
        case .updateUser(let username), .deleteUser(let username):
            return "/admin/users/\(username)"
        case .passkeyRegisterOptions: return "/auth/passkey/register/options"
        case .passkeyRegisterVerify: return "/auth/passkey/register/verify"
        case .passkeyLoginOptions: return "/auth/passkey/login/options"
        case .passkeyLoginVerify: return "/auth/passkey/login/verify"
        case .passkeyCredentials: return "/auth/passkey/credentials"
        case .passkeyDeleteCredential(let id): return "/auth/passkey/credentials/\(id)"
        }
    }

    /// このエンドポイントで使用する HTTP メソッド（GET / POST / PATCH / DELETE）。
    var method: String {
        switch self {
        case .feed, .podcasts, .podcast, .sources, .featuredSources, .onboardingStatus,
             .me, .listUsers, .passkeyCredentials:
            return "GET"
        case .starArticle, .dismissArticle, .addSource, .completeOnboarding,
             .login, .logout, .changePassword, .createUser,
             .passkeyRegisterOptions, .passkeyRegisterVerify,
             .passkeyLoginOptions, .passkeyLoginVerify:
            return "POST"
        case .updateProfile, .updateUser:
            return "PATCH"
        case .removeSource, .deleteUser, .passkeyDeleteCredential:
            return "DELETE"
        }
    }
}
