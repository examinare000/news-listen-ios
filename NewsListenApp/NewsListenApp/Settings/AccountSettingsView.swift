//
//  AccountSettingsView.swift
//  NewsListenApp
//
//  設定画面の「アカウント」セクション。プロフィール（表示名）編集・パスワード変更・
//  ログアウト、および管理者にはユーザー管理画面への導線を提供する。
//

import SwiftUI

/// 設定 Form 内に配置するアカウント管理セクション。
struct AccountSettingsView: View {
    /// アプリ全体で共有する設定・認証状態。
    @EnvironmentObject private var appState: AppState

    /// 入力中の表示名。
    @State private var displayName = ""
    /// 入力中の現在パスワード。
    @State private var currentPassword = ""
    /// 入力中の新パスワード。
    @State private var newPassword = ""
    /// 操作結果のフィードバック文言。
    @State private var message: String?

    var body: some View {
        Section("アカウント") {
            if let user = appState.currentUser {
                LabeledContent("ログイン中", value: "\(user.displayName)（\(user.username) / \(user.role)）")
            }

            // 表示名の更新
            HStack {
                TextField("表示名", text: $displayName)
                Button("更新") { Task { await saveProfile() } }
                    .buttonStyle(.borderless)
            }

            // パスワード変更
            SecureField("現在のパスワード", text: $currentPassword)
            SecureField("新しいパスワード（8文字以上）", text: $newPassword)
            Button("パスワードを変更") { Task { await changePassword() } }

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            // 管理者のみ: ユーザー管理画面
            if appState.currentUser?.isAdmin == true {
                NavigationLink("ユーザー管理") {
                    AdminUsersView(apiClient: appState.apiClient)
                }
            }

            Button("ログアウト", role: .destructive) {
                Task { await appState.logout() }
            }
        }
        .onAppear { displayName = appState.currentUser?.displayName ?? "" }
    }

    /// 表示名をサーバへ保存し、ローカル状態も更新する。
    private func saveProfile() async {
        guard let client = appState.apiClient else { return }
        do {
            let updated = try await client.updateProfile(displayName: displayName)
            appState.currentUser = updated
            message = "表示名を更新しました"
        } catch {
            message = "表示名の更新に失敗しました"
        }
    }

    /// 現在パスワードを検証して新パスワードへ変更する。
    private func changePassword() async {
        guard newPassword.count >= 8 else {
            message = "新しいパスワードは8文字以上にしてください"
            return
        }
        guard let client = appState.apiClient else { return }
        do {
            try await client.changePassword(current: currentPassword, new: newPassword)
            currentPassword = ""
            newPassword = ""
            message = "パスワードを変更しました"
        } catch let APIError.httpError(code) where code == 400 {
            message = "現在のパスワードが正しくありません"
        } catch {
            message = "パスワード変更に失敗しました"
        }
    }
}
