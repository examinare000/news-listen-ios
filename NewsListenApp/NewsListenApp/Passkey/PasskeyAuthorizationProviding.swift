//
//  PasskeyAuthorizationProviding.swift
//  NewsListenApp
//
//  Passkey 操作の port プロトコル。ViewModel はこのプロトコルにのみ依存し、
//  AuthenticationServices を直接参照しない。テスト時は MockPasskeyProvider を注入する。
//  Foundation のみに依存（AuthenticationServices は ASAuthorizationPasskeyProvider.swift に閉じる）。
//

import Foundation

// MARK: - Error

/// Passkey 操作で発生しうるエラー。
enum PasskeyError: Error {
    /// ユーザーが認証をキャンセルした。失敗扱いせず、errorMessage を設定しない。
    case canceled
    /// 認証器の操作に失敗した。ラップした元エラーをログ用に保持する。
    case failed(Error)
    /// このデバイスは Passkey をサポートしていない（iOS 16 未満等）。
    case notSupported
}

// MARK: - Protocol

/// Passkey 登録・認証を抽象化するポートプロトコル。
///
/// ViewModel はこのプロトコルのみに依存する。
/// - 本番実装: `ASAuthorizationPasskeyProvider`（AuthenticationServices を内包する唯一の殻）。
/// - テスト実装: `MockPasskeyProvider`（PasskeyTestHelpers.swift）。
protocol PasskeyAuthorizationProviding {
    /// Passkey クレデンシャルを新規登録する。
    ///
    /// - Parameter options: バックエンドから取得してデコードした登録オプション。
    /// - Returns: デバイス認証器が生成した登録クレデンシャル。
    /// - Throws: ユーザーキャンセル → `PasskeyError.canceled`。失敗 → `PasskeyError.failed`。
    func createCredential(_ options: PasskeyRegistrationOptions) async throws -> PasskeyRegistrationCredential

    /// Passkey クレデンシャルを使って認証する。
    ///
    /// - Parameter options: バックエンドから取得してデコードした認証オプション。
    /// - Returns: デバイス認証器が生成した認証クレデンシャル。
    /// - Throws: ユーザーキャンセル → `PasskeyError.canceled`。失敗 → `PasskeyError.failed`。
    func assertCredential(_ options: PasskeyAssertionOptions) async throws -> PasskeyAssertionCredential
}
