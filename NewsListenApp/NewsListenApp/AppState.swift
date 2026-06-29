//
//  AppState.swift
//  NewsListenApp
//
//  アプリ全体で共有するユーザー設定（API URL・キー・難易度・再生速度）を
//  UserDefaults で永続化する。SwiftUI から @StateObject / @EnvironmentObject で参照する。
//

import Foundation
import Combine

/// 記事タップ時の遷移先。アプリ内 Safari（既定）か外部 Safari かを選べる（要件 §3.2/§3.6・AC-5）。
enum ArticleOpenMode: String, CaseIterable, Identifiable {
    /// アプリ内 Safari（`SFSafariViewController`）で開く。
    case inApp = "in_app"
    /// 外部 Safari アプリで開く。
    case external = "external"

    /// `ForEach` 等で利用する一意な識別子（rawValue を流用）。
    var id: String { rawValue }

    /// 設定画面の Picker に表示する日本語ラベル。
    var label: String {
        switch self {
        case .inApp: return "アプリ内 Safari"
        case .external: return "外部 Safari"
        }
    }
}

/// アプリ全体で共有するユーザー設定を保持し、`UserDefaults` へ永続化する状態オブジェクト。
///
/// API URL・キー・既定の難易度・再生速度・記事の開き方を管理する。SwiftUI から
/// `@StateObject` / `@EnvironmentObject` で参照する。
///
/// - Note: `apiClient` で `@MainActor` 分離の ``APIClient`` を生成するため、`AppState` 自体も
///   `@MainActor` にする。UI 状態であり常にメインスレッドで更新されるため分離方針とも整合する。
@MainActor
final class AppState: ObservableObject {
    /// 各設定値に対応する `UserDefaults` のキー。
    private enum Keys {
        static let defaultDifficulty = "default_difficulty"
        static let defaultPlaybackSpeed = "default_playback_speed"
        static let articleOpenMode = "article_open_mode"
        static let timeFormat = "time_format"
    }

    /// API のベース URL。ビルド時に `Secrets.xcconfig` → Info.plist 経由で注入する（ADR-037）。
    /// ユーザー入力・UserDefaults 保存は廃止し、実行時は不変。
    let apiBaseURL: String

    /// API キー（共有ゲートウェイキー）。ビルド時に `Secrets.xcconfig` → Info.plist 経由で
    /// 注入する（ADR-037）。ユーザー入力・UserDefaults 保存は廃止し、実行時は不変。
    let apiKey: String

    /// Podcast 生成時の既定難易度。変更時に `UserDefaults` へ保存する。
    @Published var defaultDifficulty: String {
        didSet { UserDefaults.standard.set(defaultDifficulty, forKey: Keys.defaultDifficulty) }
    }

    /// 既定の再生速度。変更時に `UserDefaults` へ保存する。
    @Published var defaultPlaybackSpeed: Double {
        didSet { UserDefaults.standard.set(defaultPlaybackSpeed, forKey: Keys.defaultPlaybackSpeed) }
    }

    /// 記事タップ時の開き方。変更時に `UserDefaults` へ保存する。
    @Published var articleOpenMode: ArticleOpenMode {
        didSet { UserDefaults.standard.set(articleOpenMode.rawValue, forKey: Keys.articleOpenMode) }
    }

    /// 記事の日付表記方式（"absolute" | "relative"）。変更時に `UserDefaults` へ保存する。
    @Published var timeFormat: String {
        didSet { UserDefaults.standard.set(timeFormat, forKey: Keys.timeFormat) }
    }

    /// 初回オンボーディング（おすすめ追加ステップ）の完了状態。
    ///
    /// サーバ側（`UserPrefs.onboarding_completed`）が正であり、起動ごとに取得する。
    /// `nil`=未取得（判定保留）。`false` のときのみ追加ステップを提示する。
    /// launch 時のブロッキングを避けるため、ルーティングは `ContentView` 上の fullScreenCover で行う。
    @Published var onboardingCompleted: Bool?

    /// 認証状態。ログイン画面の出し分けに使う。`.unknown` は /auth/me 解決前。
    @Published var authStatus: AuthStatus = .unknown

    /// ログイン中ユーザー。未ログイン時は `nil`。
    @Published var currentUser: AuthUser?

    /// プッシュ通知タップで開く対象 Podcast ID（ディープリンク・issue #80）。
    /// 設定されると Podcast タブへ遷移して再生する。遷移後は受け手が nil に戻す。
    @Published var selectedPodcastId: String?

    /// 取得済みの APNs デバイストークン（16 進）。未取得なら `nil`。
    /// 資格情報ではないがログには出さない。認証確立後に backend へ登録する。
    private(set) var apnsDeviceToken: String?

    /// セッショントークンの保管先（既定は Keychain、テストはインメモリ）。
    private let sessionStore: SessionStore

    /// 現在の設定から生成した ``APIClient``。URL・キーが未設定または URL 不正の場合は `nil`。
    ///
    /// セッショントークンがあれば付与し、ユーザー認証付きで通信する。
    var apiClient: APIClient? {
        guard !apiBaseURL.isEmpty, !apiKey.isEmpty,
              let url = URL(string: apiBaseURL) else { return nil }
        return APIClient(baseURL: url, apiKey: apiKey, sessionToken: sessionStore.token)
    }

    /// API URL とキーがともに設定済みかどうか。初期設定画面の出し分けに使う。
    var isConfigured: Bool { !apiBaseURL.isEmpty && !apiKey.isEmpty }

    // MARK: - 認証

    /// ログイン成功を受けてトークンを Keychain に保存し、ユーザー状態を更新する。
    /// - Parameter response: ログイン API のレスポンス。
    func completeLogin(_ response: LoginResponse) {
        sessionStore.token = response.token
        currentUser = response.user
        authStatus = .authenticated
        // ログイン直後、取得済みトークンがあれば backend に登録する。
        Task { await registerDeviceTokenIfPossible() }
    }

    // MARK: - Push（APNs デバイストークン）

    /// AppDelegate から APNs デバイストークンを受け取り、可能なら backend へ登録する。
    /// - Parameter token: 16 進のデバイストークン。
    func didRegisterDeviceToken(_ token: String) {
        apnsDeviceToken = token
        Task { await registerDeviceTokenIfPossible() }
    }

    /// 認証済みかつトークン取得済みのとき、デバイストークンを backend へ登録する（ベストエフォート）。
    func registerDeviceTokenIfPossible() async {
        guard case .authenticated = authStatus,
              let apiClient, let token = apnsDeviceToken else { return }
        _ = try? await apiClient.registerDeviceToken(token)
    }

    /// プッシュ通知タップで対象 Podcast へ遷移する（ディープリンク）。
    /// - Parameter podcastId: 遷移先の Podcast ID。
    func handleNotificationPodcastId(_ podcastId: String) {
        selectedPodcastId = podcastId
    }

    /// 保存済みトークンで `/auth/me` を解決し、認証状態を確定する。
    /// 認証成功後、サーバーから preferences を取得してローカル設定を同期する。
    ///
    /// 未設定・トークン無し・失効はすべて未認証として扱い、トークンを破棄する。
    func refreshAuth() async {
        guard isConfigured, sessionStore.token != nil, let apiClient else {
            authStatus = .unauthenticated
            return
        }
        do {
            currentUser = try await apiClient.fetchMe()
            authStatus = .authenticated
            // 認証確立後、サーバーの preferences を同期する（失敗時は既存のローカル値を保持）
            await refreshPreferences()
            // 起動時に取得済みのデバイストークンがあれば backend へ登録する。
            await registerDeviceTokenIfPossible()
        } catch {
            sessionStore.token = nil
            currentUser = nil
            authStatus = .unauthenticated
        }
    }

    /// サーバーから preferences を取得し、ローカルの defaultDifficulty / defaultPlaybackSpeed を更新する。
    /// 取得失敗時は既存値を保持する（ベストエフォート）。
    func refreshPreferences() async {
        guard let apiClient else { return }
        do {
            let preferences = try await apiClient.fetchPreferences()
            if let difficulty = preferences.defaultDifficulty {
                defaultDifficulty = difficulty
            }
            if let speed = preferences.defaultPlaybackSpeed {
                defaultPlaybackSpeed = speed
            }
        } catch {
            // サイレント失敗。ローカルの既存値を保持。
        }
    }

    /// ログアウトしてサーバ側セッションを破棄し、ローカル状態を未認証にする。
    ///
    /// サーバ失効に失敗してもローカルのトークン・状態は必ず落とす（ベストエフォート）。
    func logout() async {
        if let apiClient {
            // 他ユーザーへの誤配信を避けるため、ログアウト前にデバイストークンの解除を試みる
            // （ベストエフォート。失敗してもサーバ側セッション破棄でトークンは事実上孤立する）。
            if let token = apnsDeviceToken {
                _ = try? await apiClient.unregisterDeviceToken(token)
            }
            _ = try? await apiClient.logout()
        }
        sessionStore.token = nil
        currentUser = nil
        authStatus = .unauthenticated
    }

    /// サーバから初回オンボーディング状態を取得し `onboardingCompleted` を更新する。
    ///
    /// 取得失敗時は `true` 扱いとし、追加ステップを挟まずフィードへ進ませる（行き止まりを防ぐ）。
    func refreshOnboardingStatus() async {
        guard let apiClient else { return }
        do {
            let status = try await apiClient.fetchOnboardingStatus()
            onboardingCompleted = status.onboardingCompleted
        } catch {
            onboardingCompleted = true
        }
    }

    /// 初回オンボーディング完了をサーバに記録し、ローカル状態も完了にする。
    ///
    /// 保存に失敗しても UI 上は完了として扱い、追加ステップを閉じる（次回起動時に再取得される）。
    func completeOnboarding() async {
        defer { onboardingCompleted = true }
        guard let apiClient else { return }
        _ = try? await apiClient.completeOnboarding()
    }

    /// ビルド時に Secrets.xcconfig → Info.plist 経由で注入された既定値を読む。
    ///
    /// 未注入（空文字や未置換のまま）の場合は `nil` を返す。
    /// - Parameter key: Info.plist のキー名。
    private static func injectedValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // xcconfig 未設定時は "$(API_KEY)" のような未置換文字列が残るため弾く。
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// 永続化済みの設定を読み込んで状態を初期化する。
    ///
    /// API URL・キーはビルド注入値(Info.plist←Secrets.xcconfig)のみを読む（ADR-037、#25）。
    /// その他の値は「ユーザーが保存した値(UserDefaults) > 既定値」の優先順位で決定する。
    /// - Parameter sessionStore: セッショントークンの保管先。既定は Keychain。テストで差し替える。
    init(sessionStore: SessionStore = KeychainSessionStore()) {
        self.sessionStore = sessionStore
        // API URL・キーはビルド時注入のみ（ユーザー入力・UserDefaults フォールバックは廃止）。
        self.apiBaseURL = Self.injectedValue("APIBaseURL") ?? ""
        self.apiKey = Self.injectedValue("APIKey") ?? ""
        self.defaultDifficulty = UserDefaults.standard.string(forKey: Keys.defaultDifficulty) ?? "toeic_900"
        self.defaultPlaybackSpeed = UserDefaults.standard.double(forKey: Keys.defaultPlaybackSpeed).nonZero ?? 1.0
        self.articleOpenMode = ArticleOpenMode(rawValue: UserDefaults.standard.string(forKey: Keys.articleOpenMode) ?? "") ?? .inApp
        self.timeFormat = UserDefaults.standard.string(forKey: Keys.timeFormat) ?? "absolute"
    }
}

extension Double {
    /// 0 のとき `nil`、それ以外は自身を返す。未設定（0）の既定値を `??` で補う用途に使う。
    var nonZero: Double? { self == 0 ? nil : self }
}
