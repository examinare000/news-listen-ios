//
//  AppState.swift
//  NewsListenApp
//
//  アプリ全体で共有するユーザー設定（API URL・キー・難易度・再生速度）を
//  UserDefaults で永続化する。SwiftUI から @StateObject / @EnvironmentObject で参照する。
//

import Foundation
import Combine

// 記事タップ時の遷移先。アプリ内 Safari（既定）か外部 Safari かを選べる（要件 §3.2/§3.6・AC-5）。
enum ArticleOpenMode: String, CaseIterable, Identifiable {
    case inApp = "in_app"
    case external = "external"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inApp: return "アプリ内 Safari"
        case .external: return "外部 Safari"
        }
    }
}

// apiClient で @MainActor 分離の APIClient を生成するため、AppState 自体も @MainActor にする。
// UI 状態であり常にメインスレッドで更新されるため分離方針とも整合する。
@MainActor
final class AppState: ObservableObject {
    // UserDefaults キー
    private enum Keys {
        static let apiBaseURL = "api_base_url"
        static let apiKey = "api_key"
        static let defaultDifficulty = "default_difficulty"
        static let defaultPlaybackSpeed = "default_playback_speed"
        static let articleOpenMode = "article_open_mode"
    }

    @Published var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: Keys.apiBaseURL) }
    }

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Keys.apiKey) }
    }

    @Published var defaultDifficulty: String {
        didSet { UserDefaults.standard.set(defaultDifficulty, forKey: Keys.defaultDifficulty) }
    }

    @Published var defaultPlaybackSpeed: Double {
        didSet { UserDefaults.standard.set(defaultPlaybackSpeed, forKey: Keys.defaultPlaybackSpeed) }
    }

    @Published var articleOpenMode: ArticleOpenMode {
        didSet { UserDefaults.standard.set(articleOpenMode.rawValue, forKey: Keys.articleOpenMode) }
    }

    var apiClient: APIClient? {
        guard !apiBaseURL.isEmpty, !apiKey.isEmpty,
              let url = URL(string: apiBaseURL) else { return nil }
        return APIClient(baseURL: url, apiKey: apiKey)
    }

    var isConfigured: Bool { !apiBaseURL.isEmpty && !apiKey.isEmpty }

    // ビルド時に Secrets.xcconfig → Info.plist 経由で注入された既定値を読む。
    // 未注入（空文字や未置換のまま）の場合は nil を返す。
    private static func injectedValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // xcconfig 未設定時は "$(API_KEY)" のような未置換文字列が残るため弾く。
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

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
    var nonZero: Double? { self == 0 ? nil : self }
}
