//
//  PasskeyRegistrationViewModel.swift
//  NewsListenApp
//
//  Passkey 登録フローのロジック。設定画面から呼ぶ。
//  AuthenticationServices を直接 import せず、PasskeyAuthorizationProviding プロトコルのみに依存する。
//  フロー: register/options 取得 → PasskeyOptionsDecoder → provider.createCredential
//          → PasskeyCredentialEncoder → register/verify → onSuccess
//

import Combine
import Foundation

/// Passkey 登録画面の状態と実行処理を担う ViewModel。
@MainActor
final class PasskeyRegistrationViewModel: ObservableObject {
    /// ユーザーに表示するエラー文言（なければ nil）。キャンセル時は設定しない。
    @Published var errorMessage: String?
    /// 処理実行中フラグ。
    @Published private(set) var isRunning = false

    private let apiClient: APIClient
    private let provider: PasskeyAuthorizationProviding
    private let onSuccess: () -> Void

    /// - Parameters:
    ///   - apiClient: ログイン済みセッショントークン付きのクライアント（register/options は Bearer 要）。
    ///   - provider: Passkey 操作プロバイダ（テスト時はモックを注入）。
    ///   - onSuccess: 登録成功時のコールバック（UI 更新・一覧リロード等は呼び出し側が担う）。
    init(
        apiClient: APIClient,
        provider: PasskeyAuthorizationProviding,
        onSuccess: @escaping () -> Void = {}
    ) {
        self.apiClient = apiClient
        self.provider = provider
        self.onSuccess = onSuccess
    }

    /// Passkey 登録フローを実行する。
    ///
    /// 1. register/options 取得（Bearer 要）
    /// 2. PasskeyOptionsDecoder でドメイン型へ変換
    /// 3. provider.createCredential（デバイス認証器で新規 Passkey を生成）
    /// 4. PasskeyCredentialEncoder で dict へ変換
    /// 5. register/verify（クレデンシャルをサーバに保存）
    /// 6. onSuccess コールバック
    func register() async {
        isRunning = true
        errorMessage = nil
        do {
            let optionsResp = try await apiClient.passkeyRegisterOptions()
            let regOptions = try PasskeyOptionsDecoder.decodeRegistration(from: optionsResp)
            let credential = try await provider.createCredential(regOptions)
            let credentialDict = PasskeyCredentialEncoder.encodeRegistration(credential)
            try await apiClient.passkeyRegisterVerify(
                challengeID: optionsResp.challengeID,
                credential: credentialDict
            )
            isRunning = false
            onSuccess()
        } catch PasskeyError.canceled {
            // キャンセルは失敗扱いしない。
            isRunning = false
        } catch let APIError.httpError(statusCode) where statusCode == 409 {
            // 既登録クレデンシャルには専用メッセージを表示する（バックエンド仕様通り）。
            errorMessage = "この Passkey はすでに登録されています"
            isRunning = false
        } catch {
            errorMessage = "Passkey の登録に失敗しました"
            isRunning = false
        }
    }
}
