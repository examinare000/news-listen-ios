//
//  PasskeyCredentialsViewModel.swift
//  NewsListenApp
//
//  Passkey クレデンシャル一覧・削除のロジック（優先度低）。
//  GET /auth/passkey/credentials と DELETE /auth/passkey/credentials/{id} を担う。
//

import Combine
import Foundation

/// Passkey クレデンシャル一覧画面の状態と操作を担う ViewModel。
@MainActor
final class PasskeyCredentialsViewModel: ObservableObject {
    @Published private(set) var credentials: [PasskeyCredentialItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let apiClient: APIClient?

    init(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    /// クレデンシャル一覧をサーバから取得する。
    func loadCredentials() async {
        isLoading = true
        errorMessage = nil
        guard let apiClient else {
            errorMessage = "API クライアントが未設定です"
            isLoading = false
            return
        }
        do {
            let resp = try await apiClient.listPasskeyCredentials()
            credentials = resp.credentials
        } catch {
            errorMessage = "クレデンシャル一覧の取得に失敗しました"
        }
        isLoading = false
    }

    /// 指定 credential ID を削除する。冪等（404 は無視）。
    func deleteCredential(id: String) async {
        guard let apiClient else {
            errorMessage = "API クライアントが未設定です"
            return
        }
        do {
            try await apiClient.deletePasskeyCredential(id: id)
            credentials.removeAll { $0.credentialID == id }
        } catch APIError.httpError(404) {
            // サーバ側でも既に削除済み → 冪等として扱う。
            credentials.removeAll { $0.credentialID == id }
        } catch {
            errorMessage = "Passkey の削除に失敗しました"
        }
    }
}
