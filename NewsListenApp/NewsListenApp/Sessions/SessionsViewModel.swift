//
//  SessionsViewModel.swift
//  NewsListenApp
//
//  ログイン中のデバイス/セッション一覧・個別失効・一括失効のロジック（issue #84）。
//  GET /auth/sessions / DELETE /auth/sessions/{id} / POST /auth/sessions/revoke-others を担う。
//  PasskeyCredentialsViewModel と同じ流儀。
//

import Combine
import Foundation

/// ログイン中のデバイス（セッション）画面の状態と操作を担う ViewModel。
@MainActor
final class SessionsViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// 一括失効した件数のフィードバック（なければ nil）。
    @Published var revokedOthersCount: Int?

    private let apiClient: APIClient?

    init(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    /// 有効セッション一覧をサーバから取得する。
    func loadSessions() async {
        isLoading = true
        errorMessage = nil
        revokedOthersCount = nil   // 再読み込み時に一括失効のフィードバックを消す。
        guard let apiClient else {
            errorMessage = "API クライアントが未設定です"
            isLoading = false
            return
        }
        do {
            let resp = try await apiClient.listSessions()
            sessions = resp.sessions
        } catch {
            errorMessage = "デバイス一覧の取得に失敗しました"
        }
        isLoading = false
    }

    /// 指定セッションを個別失効する。404（他人/不在）は冪等成功として扱う。
    func revokeSession(id: String) async {
        guard let apiClient else {
            errorMessage = "API クライアントが未設定です"
            return
        }
        revokedOthersCount = nil   // 個別操作時は一括失効のフィードバックを消す。
        do {
            try await apiClient.revokeSession(id: id)
            sessions.removeAll { $0.id == id }
        } catch APIError.httpError(404) {
            // サーバ側でも既に失効済み → 冪等として扱う。
            sessions.removeAll { $0.id == id }
        } catch {
            errorMessage = "ログアウトに失敗しました"
        }
    }

    /// 現在以外のセッションを一括失効する（「他のデバイスからログアウト」）。
    func revokeOthers() async {
        guard let apiClient else {
            errorMessage = "API クライアントが未設定です"
            return
        }
        do {
            let resp = try await apiClient.revokeOtherSessions()
            revokedOthersCount = resp.revokedCount
            await loadSessions()
        } catch {
            errorMessage = "一括ログアウトに失敗しました"
        }
    }
}
