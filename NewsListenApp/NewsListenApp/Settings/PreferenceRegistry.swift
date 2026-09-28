//
//  PreferenceRegistry.swift
//  NewsListenApp
//
//  設定宣言（key・scope・subjectScoped・値域・既定値）を 1 箇所に集約する（I-S2 / CI-T17）。
//  `AppState.Keys`・`DSFeedback` の AppStorage key・`AchievementCelebrationTracker` の key
//  文字列宣言はここへ一本化し、他ファイルは本ファイルの key 定数を参照する別名にする。
//

import Foundation

/// 設定値の保存範囲。
enum PreferenceScope: Equatable {
    /// backend と同期する（主体の server 設定）。
    case server
    /// 端末ローカルのみ（backend と同期しない）。
    case local
}

/// registry に登録する 1 設定の型付き宣言。
///
/// `init` は本ファイル内に限定する（fileprivate）。これにより「registry 外での宣言」
/// （registry 外 key への読み書きの構築）を型で不能にする（spec §3.3・grep oracle O-4）。
struct PreferenceSetting<Value> {
    /// `UserDefaults` のキー（不変）。
    let key: String
    /// 保存範囲。
    let scope: PreferenceScope
    /// 主体離脱時に消去する対象かどうか。
    let subjectScoped: Bool
    /// 未保存・列挙外・型不一致のときに使う既定値。
    let defaultValue: Value

    fileprivate let decode: (Any) -> Value?
    fileprivate let encode: (Value) -> Any
    fileprivate let isValid: (Value) -> Bool

    fileprivate init(
        key: String,
        scope: PreferenceScope,
        subjectScoped: Bool,
        defaultValue: Value,
        decode: @escaping (Any) -> Value?,
        encode: @escaping (Value) -> Any,
        isValid: @escaping (Value) -> Bool = { _ in true }
    ) {
        self.key = key
        self.scope = scope
        self.subjectScoped = subjectScoped
        self.defaultValue = defaultValue
        self.decode = decode
        self.encode = encode
        self.isValid = isValid
    }
}

/// 設定宣言の単一の正本（spec §3.3）。
///
/// `AppState` はここへ注入した `UserDefaults` 経由で読み書きする（`AppState.swift` は
/// `UserDefaults` を直接扱わない: grep oracle O-5）。
final class PreferenceRegistry {
    // MARK: - key 定数（他ファイルはこれを参照する別名にする。key 文字列リテラルは本ファイルに限定: O-3）

    static let defaultDifficultyKey = "default_difficulty"
    static let defaultPlaybackSpeedKey = "default_playback_speed"
    static let weeklyGoalEpisodesKey = "weekly_goal_episodes"
    static let seenAchievementIdsKey = "seen_achievement_ids"
    static let articleOpenModeKey = "article_open_mode"
    static let timeFormatKey = "time_format"
    static let sfxEnabledKey = "sfx_enabled"
    static let hapticsEnabledKey = "haptics_enabled"

    private let defaults: UserDefaults

    let defaultDifficulty: PreferenceSetting<String>
    let defaultPlaybackSpeed: PreferenceSetting<Double>
    let weeklyGoalEpisodes: PreferenceSetting<Int>
    let seenAchievementIds: PreferenceSetting<[String]>
    let articleOpenMode: PreferenceSetting<String>
    let timeFormat: PreferenceSetting<String>
    let sfxEnabled: PreferenceSetting<Bool>
    let hapticsEnabled: PreferenceSetting<Bool>

    /// registry が知る全 key（§3.3 の 8 key）。
    let allKeys: Set<String>
    /// 主体離脱時に消去する key（`defaultDifficulty` / `defaultPlaybackSpeed` /
    /// `weeklyGoalEpisodes` / `seenAchievementIds`）。
    let subjectScopedKeys: Set<String>

    /// - Parameter defaults: 読み書きに使う `UserDefaults`（既定は `.standard`。テストは suite を注入）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaultDifficulty = PreferenceSetting(
            key: Self.defaultDifficultyKey,
            scope: .server,
            subjectScoped: true,
            defaultValue: "toeic_600",
            decode: { $0 as? String },
            encode: { $0 },
            isValid: { DifficultyLabel.allCodes.contains($0) }
        )
        defaultPlaybackSpeed = PreferenceSetting(
            key: Self.defaultPlaybackSpeedKey,
            scope: .server,
            subjectScoped: true,
            defaultValue: 1.0,
            decode: { $0 as? Double },
            encode: { $0 },
            isValid: { value in PlaybackConstants.speeds.contains(Float(value)) }
        )
        weeklyGoalEpisodes = PreferenceSetting(
            key: Self.weeklyGoalEpisodesKey,
            scope: .server,
            subjectScoped: true,
            defaultValue: 3,
            decode: { $0 as? Int },
            encode: { $0 },
            isValid: { [3, 5, 7, 10].contains($0) }
        )
        seenAchievementIds = PreferenceSetting(
            key: Self.seenAchievementIdsKey,
            scope: .local,
            subjectScoped: true,
            defaultValue: [],
            decode: { $0 as? [String] },
            encode: { $0 }
        )
        articleOpenMode = PreferenceSetting(
            key: Self.articleOpenModeKey,
            scope: .local,
            subjectScoped: false,
            defaultValue: ArticleOpenMode.inApp.rawValue,
            decode: { $0 as? String },
            encode: { $0 },
            isValid: { ArticleOpenMode(rawValue: $0) != nil }
        )
        timeFormat = PreferenceSetting(
            key: Self.timeFormatKey,
            scope: .local,
            subjectScoped: false,
            defaultValue: "absolute",
            decode: { $0 as? String },
            encode: { $0 },
            isValid: { ["absolute", "relative"].contains($0) }
        )
        sfxEnabled = PreferenceSetting(
            key: Self.sfxEnabledKey,
            scope: .local,
            subjectScoped: false,
            defaultValue: true,
            decode: { $0 as? Bool },
            encode: { $0 }
        )
        hapticsEnabled = PreferenceSetting(
            key: Self.hapticsEnabledKey,
            scope: .local,
            subjectScoped: false,
            defaultValue: true,
            decode: { $0 as? Bool },
            encode: { $0 }
        )

        allKeys = [
            Self.defaultDifficultyKey, Self.defaultPlaybackSpeedKey, Self.weeklyGoalEpisodesKey,
            Self.seenAchievementIdsKey, Self.articleOpenModeKey, Self.timeFormatKey,
            Self.sfxEnabledKey, Self.hapticsEnabledKey,
        ]
        subjectScopedKeys = [
            Self.defaultDifficultyKey, Self.defaultPlaybackSpeedKey,
            Self.weeklyGoalEpisodesKey, Self.seenAchievementIdsKey,
        ]
    }

    /// 設定値を読む。未保存・型不一致・列挙外はすべて `setting.defaultValue` を返す（throw しない）。
    func get<Value>(_ setting: PreferenceSetting<Value>) -> Value {
        guard let raw = defaults.object(forKey: setting.key),
              let decoded = setting.decode(raw),
              setting.isValid(decoded) else {
            return setting.defaultValue
        }
        return decoded
    }

    /// 設定値を保存する。列挙外の値は保存せず `false` を返す（既存値は変えない）。
    @discardableResult
    func set<Value>(_ setting: PreferenceSetting<Value>, _ value: Value) -> Bool {
        guard setting.isValid(value) else { return false }
        defaults.set(setting.encode(value), forKey: setting.key)
        return true
    }

    /// `subjectScopedKeys` の key をすべて削除する（端末設定・registry 外 key は残す）。冪等。
    func clearSubjectScoped() {
        for key in subjectScopedKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
