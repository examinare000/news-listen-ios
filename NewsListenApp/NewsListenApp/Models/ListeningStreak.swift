//
//  ListeningStreak.swift
//  NewsListenApp
//
//  聴取ストリーク（issue #165）。
//  GET /users/me/listening-streak のレスポンスに対応する Codable モデル。
//

import Foundation

/// ユーザーの連続聴取日数・本日聴取済みか・最終聴取日。
///
/// - Important: `currentStreakDays == 0` は「聴取歴なし」を意味しない。backend の
///   `compute_streak`（shared/streak.py）は、一昨日以前で連続が途切れた場合にも
///   `current_streak_days = 0` を返す（`last_listened_day` は非 `null` のまま）。
///   `lastListenedDay` が `null` になるのは、聴取記録が一度もない場合のみ。
///   0日と「記録なし」を同一視して分岐しないこと（issue #165 レビュー指摘）。
struct ListeningStreak: Codable {
    /// 連続聴取日数。`0` は「連続記録が途切れている」ことを表すのみで、
    /// 聴取歴の有無とは独立（``lastListenedDay`` を参照すること）。
    let currentStreakDays: Int
    /// 今日すでに聴取したか。
    let todayListened: Bool
    /// 最終聴取日（JST の `YYYY-MM-DD`）。聴取記録が一度もない場合のみ `nil`。
    let lastListenedDay: String?

    enum CodingKeys: String, CodingKey {
        case currentStreakDays = "current_streak_days"
        case todayListened = "today_listened"
        case lastListenedDay = "last_listened_day"
    }
}
