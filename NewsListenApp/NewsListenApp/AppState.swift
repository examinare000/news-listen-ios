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
        static let apiBaseURL = "api_base_url"
        static let apiKey = "api_key"
        static let defaultDifficulty = "default_difficulty"
        static let defaultPlaybackSpeed = "default_playback_speed"
        static let articleOpenMode = "article_open_mode"
    }

    /// API のベース URL。変更時に `UserDefaults` へ保存する。
    @Published var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: Keys.apiBaseURL) }
    }

    /// API キー。変更時に `UserDefaults` へ保存する。
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Keys.apiKey) }
    }

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

    /// 現在の設定から生成した ``APIClient``。URL・キーが未設定または URL 不正の場合は `nil`。
    var apiClient: APIClient? {
        guard !apiBaseURL.isEmpty, !apiKey.isEmpty,
              let url = URL(string: apiBaseURL) else { return nil }
        return APIClient(baseURL: url, apiKey: apiKey)
    }

    /// API URL とキーがともに設定済みかどうか。初期設定画面の出し分けに使う。
    var isConfigured: Bool { !apiBaseURL.isEmpty && !apiKey.isEmpty }

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
    /// 各値は「ユーザーが保存した値(UserDefaults) > ビルド注入値(Info.plist) > 既定値」の優先順位で決定する。
    init() {
        // 優先順位: ユーザーが保存した値(UserDefaults) > ビルド注入値(Info.plist) > 空。
        self.apiBaseURL = UserDefaults.standard.string(forKey: Keys.apiBaseURL)
            ?? Self.injectedValue("APIBaseURL") ?? ""
        self.apiKey = UserDefaults.standard.string(forKey: Keys.apiKey)
            ?? Self.injectedValue("APIKey") ?? ""
        self.defaultDifficulty = UserDefaults.standard.string(forKey: Keys.defaultDifficulty) ?? "toeic_900"
        self.defaultPlaybackSpeed = UserDefaults.standard.double(forKey: Keys.defaultPlaybackSpeed).nonZero ?? 1.0
        self.articleOpenMode = ArticleOpenMode(rawValue: UserDefaults.standard.string(forKey: Keys.articleOpenMode) ?? "") ?? .inApp
    }
}

extension Double {
    /// 0 のとき `nil`、それ以外は自身を返す。未設定（0）の既定値を `??` で補う用途に使う。
    var nonZero: Double? { self == 0 ? nil : self }
}
