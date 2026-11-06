//
//  AdminUsersViewModel.swift
//  NewsListenApp
//
//  管理者用ユーザー管理画面のロジック。一覧取得・作成・ロール変更・削除を担う。
//  手順は UserAdministration（use case）に任せ、入力の下書きと文言だけを持つ。
//

import Combine
import Foundation

/// ユーザー管理画面の状態と操作を担う ViewModel。
@MainActor
final class AdminUsersViewModel: ObservableObject {
    /// 取得済みユーザー一覧。
    @Published private(set) var users: [ManagedUser] = []
    /// エラー文言。
    @Published private(set) var errorMessage: String?

    // 作成フォーム
    @Published var newUsername = ""
    @Published var newPassword = ""
    @Published var newDisplayName = ""
    @Published var newRole = Role.user.rawValue

    private let administration: UserAdministration

    /// - Parameter administration: ユーザー管理の手順。
    init(administration: UserAdministration) {
        self.administration = administration
    }

    /// ユーザー一覧を取得する。
    func load() async {
        do {
            users = try await administration.users()
            errorMessage = nil
        } catch {
            errorMessage = "ユーザー一覧の取得に失敗しました"
        }
    }

    /// 入力フォームの内容でユーザーを作成し、一覧を再取得する。
    func create() async {
        let lengthMessage = "ユーザーIDと\(PasswordPolicy.minLength)〜\(PasswordPolicy.maxLength)文字のパスワードを入力してください"
        guard !newUsername.isEmpty else {
            errorMessage = lengthMessage
            return
        }
        do {
            try await administration.create(
                username: newUsername,
                password: newPassword,
                displayName: newDisplayName,
                role: Role(rawValue: newRole)
            )
            newUsername = ""
            newPassword = ""
            newDisplayName = ""
            newRole = Role.user.rawValue
            await load()
        } catch UserAdministrationFailure.policyViolation {
            errorMessage = lengthMessage
        } catch {
            errorMessage = "ユーザー作成に失敗しました（既に存在する可能性があります）"
        }
    }

    /// 指定ユーザーを削除し、一覧を再取得する。
    /// - Parameter username: 削除対象。
    func delete(username: String) async {
        do {
            try await administration.delete(username: username)
            await load()
        } catch {
            errorMessage = "\(username) の削除に失敗しました"
        }
    }

    /// 指定ユーザーの admin/user ロールを反転し、一覧を再取得する。
    /// - Parameter user: 対象ユーザー。
    func toggleRole(_ user: ManagedUser) async {
        let nextRole = user.role.isAdmin ? Role.user : Role.admin
        do {
            try await administration.setRole(username: user.username, role: nextRole)
            await load()
        } catch {
            errorMessage = "\(user.username) のロール変更に失敗しました"
        }
    }
}
