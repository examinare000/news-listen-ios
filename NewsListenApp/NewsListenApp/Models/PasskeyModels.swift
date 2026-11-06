//
//  PasskeyModels.swift
//  NewsListenApp
//
//  Passkey の通信のデータモデル（API レスポンス Codable 型）。
//  このファイルは Foundation のみに依存し、AuthenticationServices を一切 import しない。
//

import Foundation

// MARK: - API Response Codable types

/// POST /auth/passkey/register/options および /auth/passkey/login/options のレスポンス。
///
/// `options` は python-webauthn の `options_to_json()` 出力を文字列化したもの（二段パース要）。
struct PasskeyOptionsAPIResponse: Codable {
    /// サーバが発行したチャレンジ相関 ID（verify 時に echo する）。
    let challengeID: String
    /// WebAuthn オプションを JSON 文字列化したもの（PasskeyOptionsDecoder で二段パースする）。
    let options: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case options
    }
}

/// GET /auth/passkey/credentials のクレデンシャルアイテム。
/// public_key は除外（バックエンドも返さない）。
struct PasskeyCredentialItem: Codable, Identifiable {
    let credentialID: String
    let username: String
    /// ユーザーが設定した表示名（任意）。
    let name: String?
    let transports: [String]
    let aaguid: String?
    let signCount: Int
    /// ISO 8601 文字列（表示用）。
    let createdAt: String
    let lastUsedAt: String?

    var id: String { credentialID }

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case username
        case name
        case transports
        case aaguid
        case signCount = "sign_count"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// GET /auth/passkey/credentials のレスポンス。
struct PasskeyCredentialsAPIResponse: Codable {
    let credentials: [PasskeyCredentialItem]
}

extension PasskeyCredentialItem {
    func toCredential() -> PasskeyCredential {
        PasskeyCredential(id: credentialID, name: name, createdAt: createdAt)
    }
}
