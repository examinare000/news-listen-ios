//
//  PreferenceCatalog.swift
//  NewsListenApp
//
//  設定の一覧・主体依存かどうかの分類・端末設定の既定値（ios-rule-prefs-04）。key 名は持たない
//  （key は adapter の `PreferenceRegistry` が持つ）。
//

import Foundation

/// 設定の項目。
enum PreferenceItem: CaseIterable, Equatable, Hashable {
    case defaultDifficulty, defaultPlaybackSpeed, weeklyGoal, seenAchievements, articleOpenMode, timeFormat, soundEnabled, hapticsEnabled
}

enum PreferenceCatalog {
    /// 主体の離脱で消す項目（`PreferenceRegistry.subjectScopedKeys` と同じ 4 つ）。
    static let subjectScoped: Set<PreferenceItem> = [.defaultDifficulty, .defaultPlaybackSpeed, .weeklyGoal, .seenAchievements]

    /// サーバーと同期する項目。
    static let serverSynced: Set<PreferenceItem> = [.defaultDifficulty, .defaultPlaybackSpeed, .weeklyGoal]

    /// `PlaybackConstants.speeds` の内の値。
    static let defaultPlaybackSpeed: Double = 1.0
    static let defaultArticleOpenMode: ArticleOpenMode = .inApp
    static let defaultSoundEnabled = true
    static let defaultHapticsEnabled = true
}
