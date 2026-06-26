//
//  PasskeyCredentialEncoder.swift
//  NewsListenApp
//
//  ドメイン credential をバックエンドの verify request body 用 dict へ変換する純粋関数層。
//  Foundation のみに依存し、AuthenticationServices を一切 import しない。
//
//  バックエンド契約:
//  - 送信先: POST /auth/passkey/register/verify・login/verify
//  - ボディ: {"challenge_id": "...", "credential": {credential dict}}
//  - credential dict は WebAuthn PublicKeyCredential 形式:
//    {id, rawId, type:"public-key", response:{...}}
//  - バイナリは全て base64url（パディング無し）。
//  - 登録: response に clientDataJSON・attestationObject・transports を含む。
//  - 認証: response に clientDataJSON・authenticatorData・signature を含む。
//          userHandle は present のときのみ含める（nil なら省略）。
//

import Foundation

/// ドメイン credential を verify リクエストの `credential` dict へ変換する。
enum PasskeyCredentialEncoder {

    // MARK: - Registration

    /// 登録クレデンシャルを verify request body の `credential` dict に変換する。
    ///
    /// - Parameter credential: デバイス認証器から受け取った登録クレデンシャル。
    /// - Returns: `JSONSerialization` でシリアライズ可能な `[String: Any]`。
    static func encodeRegistration(_ credential: PasskeyRegistrationCredential) -> [String: Any] {
        let credIDStr = credential.credentialID.base64URLEncodedString()
        let response: [String: Any] = [
            "clientDataJSON": credential.clientDataJSON.base64URLEncodedString(),
            "attestationObject": credential.attestationObject.base64URLEncodedString(),
            "transports": credential.transports
        ]
        return [
            "id": credIDStr,
            "rawId": credIDStr,
            "type": "public-key",
            "response": response
        ]
    }

    // MARK: - Assertion

    /// 認証クレデンシャルを verify request body の `credential` dict に変換する。
    ///
    /// - Parameter credential: デバイス認証器から受け取った認証クレデンシャル。
    /// - Returns: `JSONSerialization` でシリアライズ可能な `[String: Any]`。
    static func encodeAssertion(_ credential: PasskeyAssertionCredential) -> [String: Any] {
        let credIDStr = credential.credentialID.base64URLEncodedString()
        var response: [String: Any] = [
            "clientDataJSON": credential.clientDataJSON.base64URLEncodedString(),
            "authenticatorData": credential.authenticatorData.base64URLEncodedString(),
            "signature": credential.signature.base64URLEncodedString()
        ]
        // userHandle は present のときのみ含める（nil 時は省略: python-webauthn は nil キーを拒否）。
        if let userHandle = credential.userHandle {
            response["userHandle"] = userHandle.base64URLEncodedString()
        }
        return [
            "id": credIDStr,
            "rawId": credIDStr,
            "type": "public-key",
            "response": response
        ]
    }
}
