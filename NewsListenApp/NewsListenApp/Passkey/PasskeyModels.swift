//
//  PasskeyModels.swift
//  NewsListenApp
//
//  Passkey ドメイン値型と API レスポンス Codable 型。
//  このファイルは Foundation のみに依存し、AuthenticationServices を一切 import しない。
//  バイナリは全て Data 型（base64url への変換は Encoder/Decoder 層で行う）。
//

import Foundation

// MARK: - Domain value types（ビジネスロジック層）

/// Passkey 登録オプション（バックエンドからデコードしたドメイン型）。
struct PasskeyRegistrationOptions {
    /// RP（Relying Party）の識別子。`ASAuthorizationPlatformPublicKeyCredentialProvider` に渡す。
    let rpID: String
    /// ワンタイムチャレンジ。base64url デコード済み Data。
    let challenge: Data
    /// ユーザー ID（user.id）。base64url デコード済み Data。
    let userID: Data
    /// ユーザーのログイン ID（user.name）。
    let userName: String
    /// ユーザーの表示名（user.displayName）。
    let userDisplayName: String
    /// 既登録クレデンシャル ID 一覧（重複登録防止用）。
    let excludeCredentialIDs: [Data]
}

/// Passkey 認証オプション（バックエンドからデコードしたドメイン型）。
struct PasskeyAssertionOptions {
    /// RP の識別子。
    let rpID: String
    /// ワンタイムチャレンジ。base64url デコード済み Data。
    let challenge: Data
    /// 許可するクレデンシャル ID 一覧（discoverable フローでは常に空）。
    let allowCredentialIDs: [Data]
}

/// Passkey 登録クレデンシャル（デバイス認証器から受け取った生バイト）。
struct PasskeyRegistrationCredential {
    let credentialID: Data
    let clientDataJSON: Data
    let attestationObject: Data
    /// クレデンシャルが使用できるトランスポート（例: ["internal", "hybrid"]）。
    let transports: [String]
}

/// Passkey 認証クレデンシャル（デバイス認証器から受け取った生バイト）。
struct PasskeyAssertionCredential {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data
    /// userHandle（WebAuthn の userID）。認証器が提供しない場合 nil。
    let userHandle: Data?
}

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
