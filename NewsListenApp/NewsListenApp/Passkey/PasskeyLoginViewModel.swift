//
//  PasskeyLoginViewModel.swift
//  NewsListenApp
//
//  Passkey ログインフローのロジック。
//  AuthenticationServices を直接 import せず、PasskeyAuthorizationProviding プロトコルのみに依存する。
//  フロー: login/options 取得 → PasskeyOptionsDecoder → provider.assertCredential
//          → PasskeyCredentialEncoder → login/verify → onSuccess
//

import Combine
import Foundation

/// Passkey ログイン画面の状態と実行処理を担う ViewModel。
@MainActor
final class PasskeyLoginViewModel: ObservableObject {
    /// ユーザーに表示するエラー文言（なければ nil）。キャンセル時は設定しない。
    @Published var errorMessage: String?
    /// 処理実行中フラグ（多重実行防止・ボタン無効化に使う）。
    @Published private(set) var isRunning = false

    private let apiClient: APIClient
    private let provider: PasskeyAuthorizationProviding
    /// ログイン成功時に呼ぶコールバック（トークン保存・認証状態更新は呼び出し側が担う）。
    private let onSuccess: (LoginResponse) -> Void

    /// - Parameters:
    ///   - apiClient: API 通信クライアント（未認証でも可: login/options は認証不要）。
    ///   - provider: Passkey 操作プロバイダ（テスト時はモックを注入）。
    ///   - onSuccess: ログイン成功時に `LoginResponse` を渡すコールバック。
    init(
        apiClient: APIClient,
        provider: PasskeyAuthorizationProviding,
        onSuccess: @escaping (LoginResponse) -> Void
    ) {
        self.apiClient = apiClient
        self.provider = provider
        self.onSuccess = onSuccess
    }

    /// Passkey 認証フローを実行する。
    ///
    /// 1. login/options 取得（CSRF 免除・Bearer 不要だが iOS は送っても問題なし）
    /// 2. PasskeyOptionsDecoder でドメイン型へ変換
    /// 3. provider.assertCredential（ASAuthorizationController 表示→ユーザー操作）
    /// 4. PasskeyCredentialEncoder で dict へ変換
    /// 5. login/verify で LoginResponse 取得
    /// 6. onSuccess コールバック
    func performLogin() async {
        isRunning = true
        errorMessage = nil
        do {
            // 1. options 取得（CSRF 免除・body: {}）
            let optionsResp = try await apiClient.passkeyLoginOptions()
            // 2. 二段パース: options(JSON文字列) → PasskeyAssertionOptions（base64url デコード済み）
            let assertionOptions = try PasskeyOptionsDecoder.decodeAssertion(from: optionsResp)
            // 3. デバイス認証器に問い合わせ（ユーザーが Face ID / Touch ID を使う）
            let credential = try await provider.assertCredential(assertionOptions)
            // 4. ドメイン credential → verify request dict（base64url エンコード）
            let credentialDict = PasskeyCredentialEncoder.encodeAssertion(credential)
            // 5. challenge_id + credential dict を verify へ送り LoginResponse を受け取る
            let loginResponse = try await apiClient.passkeyLoginVerify(
                challengeID: optionsResp.challengeID,
                credential: credentialDict
            )
            // 成功時は画面遷移するため isRunning は false に戻さない（遷移までボタン無効を維持）。
            onSuccess(loginResponse)
        } catch PasskeyError.canceled {
            // キャンセルは失敗扱いしない（errorMessage を設定しない）。
            isRunning = false
        } catch {
            errorMessage = "Passkey 認証に失敗しました"
            isRunning = false
        }
    }
}
