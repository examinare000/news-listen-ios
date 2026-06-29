//
//  AdminUsersView.swift
//  NewsListenApp
//
//  管理者用ユーザー管理画面。一覧・作成・ロール変更・削除を行う。
//

import SwiftUI

/// 管理者によるユーザー管理画面。設定画面からプッシュ遷移する。
struct AdminUsersView: View {
    /// アプリ全体で共有する状態（自分自身の削除抑止に使う）。
    @EnvironmentObject private var appState: AppState
    /// ユーザー管理ロジック。
    @StateObject private var viewModel: AdminUsersViewModel

    /// - Parameter apiClient: 認証済みクライアント（管理 API 用）。
    init(apiClient: APIClient?) {
        _viewModel = StateObject(wrappedValue: AdminUsersViewModel(apiClient: apiClient))
    }

    var body: some View {
        Form {
            Section("ユーザーを追加") {
                TextField("ユーザーID", text: $viewModel.newUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("パスワード（8文字以上）", text: $viewModel.newPassword)
                TextField("表示名（任意）", text: $viewModel.newDisplayName)
                Picker("ロール", selection: $viewModel.newRole) {
                    Text("user").tag("user")
                    Text("admin").tag("admin")
                }
                Button("追加") { Task { await viewModel.create() } }
            }

            Section("ユーザー一覧") {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(DSColor.danger).font(DSFont.footnote)
                }
                ForEach(viewModel.users) { user in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(user.displayName).foregroundStyle(DSColor.ink)
                            Text("\(user.username) / \(user.role)")
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.inkTertiary)
                        }
                        Spacer()
                        // 自分自身のロール変更・削除はさせない（自己ロックアウト防止。
                        // サーバー側でも最後の admin は 409 で保護される）。
                        if user.username != appState.currentUser?.username {
                            Button(user.isAdmin ? "user へ" : "admin へ") {
                                Task { await viewModel.toggleRole(user) }
                            }
                            .buttonStyle(.borderless)
                            Button("削除", role: .destructive) {
                                Task { await viewModel.delete(username: user.username) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.paper.ignoresSafeArea())
        .navigationTitle("ユーザー管理")
        .task { await viewModel.load() }
    }
}
