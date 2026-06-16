//
//  AppState.swift
//  NewsListenApp
//
//  アプリ全体で共有するユーザー設定（API URL・キー・難易度・再生速度）を
//  UserDefaults で永続化する。SwiftUI から @StateObject / @EnvironmentObject で参照する。
//

import Foundation
import Combine

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

    var apiClient: APIClient? {
        guard !apiBaseURL.isEmpty, !apiKey.isEmpty,
              let url = URL(string: apiBaseURL) else { return nil }
        return APIClient(baseURL: url, apiKey: apiKey)
    }

    var isConfigured: Bool { !apiBaseURL.isEmpty && !apiKey.isEmpty }

    init() {
        self.apiBaseURL = UserDefaults.standard.string(forKey: Keys.apiBaseURL) ?? ""
        self.apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
        self.defaultDifficulty = UserDefaults.standard.string(forKey: Keys.defaultDifficulty) ?? "toeic_900"
        self.defaultPlaybackSpeed = UserDefaults.standard.double(forKey: Keys.defaultPlaybackSpeed).nonZero ?? 1.0
    }
}

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
