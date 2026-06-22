//
//  AdminUsersViewModel.swift
//  NewsListenApp
//
//  管理者用ユーザー管理画面のロジック。一覧取得・作成・ロール変更・削除を担う。
//

import Combine
import Foundation

/// ユーザー管理画面の状態と操作を担う ViewModel。
@MainActor
final class AdminUsersViewModel: ObservableObject {
    /// 取得済みユーザー一覧。
    @Published private(set) var users: [AuthUser] = []
    /// エラー文言。
    @Published var errorMessage: String?

    // 作成フォーム
    @Published var newUsername = ""
    @Published var newPassword = ""
    @Published var newDisplayName = ""
    @Published var newRole = "user"

    /// 管理 API 通信に使うクライアント（認証トークン付き）。未設定時は `nil`。
    private let apiClient: APIClient?

    /// - Parameter apiClient: 認証済みクライアント。
    init(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    /// ユーザー一覧を取得する。
    func load() async {
        guard let apiClient else { return }
        do {
            users = try await apiClient.listUsers().users
            errorMessage = nil
        } catch {
            errorMessage = "ユーザー一覧の取得に失敗しました"
        }
    }

    /// 入力フォームの内容でユーザーを作成し、一覧を再取得する。
    func create() async {
        guard let apiClient else { return }
        guard !newUsername.isEmpty, newPassword.count >= 8 else {
            errorMessage = "ユーザーIDと8文字以上のパスワードを入力してください"
            return
        }
        do {
            _ = try await apiClient.createUser(
                username: newUsername,
                password: newPassword,
                displayName: newDisplayName.isEmpty ? nil : newDisplayName,
                role: newRole
            )
            newUsername = ""
            newPassword = ""
            newDisplayName = ""
            newRole = "user"
            await load()
        } catch {
            errorMessage = "ユーザー作成に失敗しました（既に存在する可能性があります）"
        }
    }

    /// 指定ユーザーを削除し、一覧を再取得する。
    /// - Parameter username: 削除対象。
    func delete(username: String) async {
        guard let apiClient else { return }
        do {
            try await apiClient.deleteUser(username: username)
            await load()
        } catch {
            errorMessage = "\(username) の削除に失敗しました"
        }
    }

    /// 指定ユーザーの admin/user ロールを反転し、一覧を再取得する。
    /// - Parameter user: 対象ユーザー。
    func toggleRole(_ user: AuthUser) async {
        guard let apiClient else { return }
        let nextRole = user.isAdmin ? "user" : "admin"
        do {
            _ = try await apiClient.updateUser(username: user.username, role: nextRole)
            await load()
        } catch {
            errorMessage = "\(user.username) のロール変更に失敗しました"
        }
    }
}
