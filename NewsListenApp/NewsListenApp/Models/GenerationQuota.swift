//
//  GenerationQuota.swift
//  NewsListenApp
//
//  Podcast 生成の本日残回数（issue #164・ADR-061）。
//  GET /users/me/generation-quota のレスポンスに対応する Codable モデル。
//

import Foundation

/// Podcast 生成の本日の上限・使用量・残回数。
///
/// `limit == 0` は無制限を表し、その場合 `remaining` はサーバーから `null` で返る
/// （ADR-061）。`resetAt` は表示専用の ISO 8601 文字列のまま保持する
/// （``SessionItem`` 等、既存の日時フィールドと同じ流儀）。
struct GenerationQuota: Codable {
    /// 本日の生成上限回数。`0` は無制限。
    let limit: Int
    /// 本日の使用済み回数。
    let used: Int
    /// 本日の残り回数。`limit == 0`（無制限）のときは `nil`。
    let remaining: Int?
    /// 上限がリセットされる日時（ISO 8601 文字列）。
    let resetAt: String

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remaining
        case resetAt = "reset_at"
    }
}
