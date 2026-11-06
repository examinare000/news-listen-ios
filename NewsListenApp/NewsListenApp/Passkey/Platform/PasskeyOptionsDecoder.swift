//
//  PasskeyOptionsDecoder.swift
//  NewsListenApp
//
//  バックエンドの `PasskeyOptionsAPIResponse.options`（JSON 文字列化 = 二段パース要）を
//  ドメイン型へ変換する純粋関数層。
//  Foundation のみに依存し、AuthenticationServices を一切 import しない。
//

import Foundation

/// python-webauthn の `options_to_json()` 出力（JSON 文字列）をドメイン型へデコードする。
///
/// バックエンド契約:
/// - `options` フィールドは JSON を文字列化したもの（二段パース）。
/// - 認証 options: `rpId`（camelCase, トップレベル）、`challenge`（base64url）、`allowCredentials`（常に空）。
/// - 登録 options: `rp.id`（ネスト）、`user.id`（base64url）、`challenge`（base64url）。
/// - バイナリは全て base64url（パディング無し、URL セーフ）。
enum PasskeyOptionsDecoder {

    /// デコード失敗の原因を表すエラー型。
    enum Error: Swift.Error {
        case malformedOptionsJSON
        case missingField(String)
        case invalidBase64URL(String)
    }

    // MARK: - Assertion（Login）

    /// 認証（login）オプションをデコードする。
    ///
    /// - Parameter response: POST /auth/passkey/login/options のレスポンス。
    /// - Returns: `PasskeyAssertionOptions`（rpID・challenge・allowCredentialIDs）。
    /// - Throws: `PasskeyOptionsDecoder.Error`（不正 JSON・必須フィールド欠損・base64url 不正）。
    static func decodeAssertion(from response: PasskeyOptionsAPIResponse) throws -> PasskeyAssertionOptions {
        let json = try parseOptionsJSON(response.options)

        guard let rpID = json["rpId"] as? String else {
            throw Error.missingField("rpId")
        }
        let challenge = try decodeChallenge(json)

        let allowCredentialIDs: [Data]
        if let allowCreds = json["allowCredentials"] as? [[String: Any]] {
            allowCredentialIDs = allowCreds.compactMap { item in
                guard let idStr = item["id"] as? String else { return nil }
                return Data(base64URLEncoded: idStr)
            }
        } else {
            allowCredentialIDs = []
        }

        return PasskeyAssertionOptions(
            rpID: rpID,
            challenge: challenge,
            allowCredentialIDs: allowCredentialIDs
        )
    }

    // MARK: - Registration

    /// 登録（register）オプションをデコードする。
    ///
    /// - Parameter response: POST /auth/passkey/register/options のレスポンス。
    /// - Returns: `PasskeyRegistrationOptions`。
    /// - Throws: `PasskeyOptionsDecoder.Error`。
    static func decodeRegistration(from response: PasskeyOptionsAPIResponse) throws -> PasskeyRegistrationOptions {
        let json = try parseOptionsJSON(response.options)

        // rp.id（python-webauthn は rp をネストオブジェクトで返す）。
        guard let rp = json["rp"] as? [String: Any],
              let rpID = rp["id"] as? String else {
            throw Error.missingField("rp.id")
        }
        let challenge = try decodeChallenge(json)

        guard let user = json["user"] as? [String: Any] else {
            throw Error.missingField("user")
        }
        guard let userIDStr = user["id"] as? String else {
            throw Error.missingField("user.id")
        }
        guard let userID = Data(base64URLEncoded: userIDStr) else {
            throw Error.invalidBase64URL("user.id")
        }
        let userName = user["name"] as? String ?? ""
        let userDisplayName = user["displayName"] as? String ?? ""

        let excludeCredentialIDs: [Data]
        if let excludeCreds = json["excludeCredentials"] as? [[String: Any]] {
            excludeCredentialIDs = excludeCreds.compactMap { item in
                guard let idStr = item["id"] as? String else { return nil }
                return Data(base64URLEncoded: idStr)
            }
        } else {
            excludeCredentialIDs = []
        }

        return PasskeyRegistrationOptions(
            rpID: rpID,
            challenge: challenge,
            userID: userID,
            userName: userName,
            userDisplayName: userDisplayName,
            excludeCredentialIDs: excludeCredentialIDs
        )
    }

    // MARK: - Private helpers

    /// `options` 文字列を二段パースして `[String: Any]` を返す。
    private static func parseOptionsJSON(_ optionsString: String) throws -> [String: Any] {
        guard let data = optionsString.data(using: .utf8) else {
            throw Error.malformedOptionsJSON
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.malformedOptionsJSON
        }
        return json
    }

    /// JSON dict から `challenge` フィールドを base64url デコードして返す。
    private static func decodeChallenge(_ json: [String: Any]) throws -> Data {
        guard let challengeStr = json["challenge"] as? String else {
            throw Error.missingField("challenge")
        }
        guard let challengeData = Data(base64URLEncoded: challengeStr) else {
            throw Error.invalidBase64URL("challenge")
        }
        return challengeData
    }
}
