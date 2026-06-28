//
//  Preferences.swift
//  NewsListenApp
//
//  ユーザーの設定選択（難易度・再生速度）をバックエンド同期する Codable モデル。
//

import Foundation

/// ユーザーの設定選択（難易度・再生速度）。
/// バックエンドの `PreferencesResponse` に対応する。
struct Preferences: Codable {
    /// 既定の Podcast 難易度（例: `toeic_900`）。
    let defaultDifficulty: String?
    /// 既定の再生速度（例: 1.5）。
    let defaultPlaybackSpeed: Double?

    /// バックエンドの snake_case フィールドに対応する。
    enum CodingKeys: String, CodingKey {
        case defaultDifficulty = "default_difficulty"
        case defaultPlaybackSpeed = "default_playback_speed"
    }
}
