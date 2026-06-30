//
//  SessionModels.swift
//  NewsListenApp
//
//  ログイン中のデバイス/セッション（issue #84）の API モデル。
//  GET /auth/sessions / DELETE /auth/sessions/{id} / POST /auth/sessions/revoke-others に対応。
//

import Foundation

/// 有効なセッション 1 件（ログイン中デバイス）。
struct SessionItem: Codable, Identifiable {
    /// セッション識別子（トークンの SHA-256 ハッシュ・失効 API で指定）。
    let sessionID: String
    /// User-Agent 由来のデバイス表示名（無ければ nil）。
    let deviceLabel: String?
    /// ISO 8601 文字列（表示用）。
    let createdAt: String
    let lastUsedAt: String?
    /// 現在のデバイスか（サーバ算出）。
    let current: Bool

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "id"
        case deviceLabel = "device_label"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case current
    }
}

/// GET /auth/sessions のレスポンス。
struct SessionsAPIResponse: Codable {
    let sessions: [SessionItem]
}

/// POST /auth/sessions/revoke-others のレスポンス。
struct RevokeSessionsAPIResponse: Codable {
    let revokedCount: Int

    enum CodingKeys: String, CodingKey {
        case revokedCount = "revoked_count"
    }
}
