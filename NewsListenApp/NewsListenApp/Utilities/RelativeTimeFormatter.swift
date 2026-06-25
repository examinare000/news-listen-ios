//
//  RelativeTimeFormatter.swift
//  NewsListenApp
//
//  ISO8601 形式の日時文字列を相対時間の日本語表記に変換する。
//  ADR-030 の仕様に従い、パース失敗時は "" を返す。
//

import Foundation

/// ISO8601 形式の日時文字列を相対時間の日本語表記に変換する。
struct RelativeTimeFormatter {
    /// 指定 ISO8601 文字列を、現在時刻 `now` との相対差分で日本語テキストに変換する。
    ///
    /// - Parameters:
    ///   - isoString: ISO8601 形式の日時文字列（例: `"2026-05-31T06:00:00Z"`）。
    ///   - now: 基準時刻。既定は `Date()`（現在時刻）。テスト用に差し替え可能。
    /// - Returns:
    ///   - パース失敗時: `""`
    ///   - 未来（diff < 0）: `"もうすぐ"`
    ///   - < 60 秒: `"たった今"`
    ///   - 1-59 分: `"N分前"`
    ///   - 1-23 時間: `"N時間前"`
    ///   - 1-29 日: `"N日前"`
    ///   - 1-11 か月（30 日単位）: `"Nか月前"`
    ///   - 1 年以上: `"N年前"（365 日単位）
    static func format(_ isoString: String, now: Date = Date()) -> String {
        guard !isoString.isEmpty else { return "" }

        // ISO8601 文字列をパースする
        let formatter = ISO8601DateFormatter()
        guard let publishedDate = formatter.date(from: isoString) else { return "" }

        let secondsElapsed = now.timeIntervalSince(publishedDate)

        // 未来の日付
        if secondsElapsed < 0 {
            return "もうすぐ"
        }

        let seconds = Int(secondsElapsed)

        // < 60 秒
        if seconds < 60 {
            return "たった今"
        }

        let minutes = seconds / 60
        // 1-59 分
        if minutes < 60 {
            return "\(minutes)分前"
        }

        let hours = minutes / 60
        // 1-23 時間
        if hours < 24 {
            return "\(hours)時間前"
        }

        let days = hours / 24
        // 1-29 日
        if days < 30 {
            return "\(days)日前"
        }

        // WHY 年を先に判定: 月=days/30・年=days/365 を独立に丸めるため、月から先に判定すると
        // 360-364 日（月=12・年=0）で "0年前" になってしまう。web ADR-030 同様に年(>=1)を先に
        // 判定し、未満なら月（最大 "12か月前"）へフォールバックする。
        let years = days / 365
        if years >= 1 {
            return "\(years)年前"
        }

        let months = days / 30
        return "\(months)か月前"
    }
}
