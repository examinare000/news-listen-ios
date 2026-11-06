//
//  PasskeyCredentialsViewModel.swift
//  NewsListenApp
//
//  Passkey クレデンシャル一覧・削除のロジック（優先度低）。
//

import Combine
import Foundation

/// Passkey クレデンシャル一覧画面の状態と操作を担う ViewModel。
@MainActor
final class PasskeyCredentialsViewModel: ObservableObject {
    @Published private(set) var credentials: [PasskeyCredential] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let enrollment: PasskeyEnrollment

    init(enrollment: PasskeyEnrollment) {
        self.enrollment = enrollment
    }

    /// クレデンシャル一覧をサーバから取得する。
    func loadCredentials() async {
        isLoading = true
        errorMessage = nil
        do {
            credentials = try await enrollment.credentials()
        } catch {
            errorMessage = "クレデンシャル一覧の取得に失敗しました"
        }
        isLoading = false
    }

    /// 指定 credential ID を削除する。冪等（404 は use case が成功にする）。
    func deleteCredential(id: String) async {
        do {
            try await enrollment.delete(id: id)
            credentials.removeAll { $0.id == id }
        } catch {
            errorMessage = "Passkey の削除に失敗しました"
        }
    }
}
