//
//  LoginViewModel.swift
//  NewsListenApp
//
//  ログイン画面のロジック。APIClient.login を呼び、成功時は onSuccess へ結果を渡す。
//  失敗時はユーザー存在を露出しない汎用文言を表示する（agent-rules/12 準拠）。
//

import Combine
import Foundation

/// ログイン画面の状態と送信処理を担う ViewModel。
@MainActor
final class LoginViewModel: ObservableObject {
    /// 入力中のユーザー ID。
    @Published var username = ""
    /// 入力中のパスワード。
    @Published var password = ""
    /// 直近のエラー文言（なければ `nil`）。
    @Published var errorMessage: String?
    /// 送信中フラグ（多重送信・ボタン無効化に使う）。
    @Published private(set) var isSubmitting = false

    /// 認証通信に使うクライアント（未ログインのためトークンは未設定）。
    private let apiClient: APIClient
    /// ログイン成功時に呼ぶコールバック（トークン保存・状態更新は呼び出し側が担う）。
    private let onSuccess: (LoginResponse) -> Void

    /// - Parameters:
    ///   - apiClient: ログイン通信に使うクライアント。
    ///   - onSuccess: 成功時に結果を渡すコールバック。
    init(apiClient: APIClient, onSuccess: @escaping (LoginResponse) -> Void) {
        self.apiClient = apiClient
        self.onSuccess = onSuccess
    }

    /// 入力が揃い送信可能か。
    var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isSubmitting
    }

    /// ログインを実行する。成功で onSuccess、失敗で errorMessage を設定する。
    func submit() async {
        guard canSubmit else {
            errorMessage = "ユーザーIDとパスワードを入力してください"
            return
        }
        isSubmitting = true
        errorMessage = nil
        do {
            let response = try await apiClient.login(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            onSuccess(response)
            // 成功時は画面遷移するため isSubmitting は false に戻さない（遷移までボタン無効を維持）。
        } catch let APIError.httpError(statusCode) where statusCode == 401 {
            errorMessage = "ユーザーIDまたはパスワードが正しくありません"
            isSubmitting = false
        } catch {
            errorMessage = "ログインに失敗しました。接続設定を確認してください"
            isSubmitting = false
        }
    }
}
