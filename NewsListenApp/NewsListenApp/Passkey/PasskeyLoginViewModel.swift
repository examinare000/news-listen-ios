//
//  PasskeyLoginViewModel.swift
//  NewsListenApp
//
//  Passkey ログインフローのロジック。手順は PasskeySignIn（use case）に任せ、状態と文言だけを持つ。
//

import Combine
import Foundation

/// Passkey ログイン画面の状態と実行処理を担う ViewModel。
@MainActor
final class PasskeyLoginViewModel: ObservableObject {
    /// ユーザーに表示するエラー文言（なければ nil）。キャンセル時は設定しない。
    @Published private(set) var errorMessage: String?
    /// 処理実行中フラグ（多重実行防止・ボタン無効化に使う）。
    @Published private(set) var isRunning = false

    private let signIn: PasskeySignIn
    /// ログイン成功時に呼ぶコールバック（トークン保存・認証状態更新は呼び出し側が担う）。
    private let onSuccess: (LoginReceipt) -> Void

    /// - Parameters:
    ///   - signIn: Passkey ログインの手順。
    ///   - onSuccess: ログイン成功時に `LoginReceipt` を渡すコールバック。
    init(signIn: PasskeySignIn, onSuccess: @escaping (LoginReceipt) -> Void) {
        self.signIn = signIn
        self.onSuccess = onSuccess
    }

    /// Passkey 認証フローを実行する。
    func performLogin() async {
        isRunning = true
        errorMessage = nil
        do {
            let receipt = try await signIn.signIn()
            // 成功時は画面遷移するため isRunning は false に戻さない（遷移までボタン無効を維持）。
            onSuccess(receipt)
        } catch PasskeyError.canceled {
            // キャンセルは失敗扱いしない（errorMessage を設定しない）。
            isRunning = false
        } catch {
            errorMessage = "Passkey 認証に失敗しました"
            isRunning = false
        }
    }
}
