//
//  AdminUsersView.swift
//  NewsListenApp
//
//  管理者用ユーザー管理画面。一覧・作成・ロール変更・削除を行う。
//

import SwiftUI

/// 管理者によるユーザー管理画面。設定画面からプッシュ遷移する。
struct AdminUsersView: View {
    /// ユーザー管理ロジック。
    @StateObject private var viewModel: AdminUsersViewModel

    /// - Parameter administration: ユーザー管理の手順。
    init(administration: UserAdministration) {
        _viewModel = StateObject(wrappedValue: AdminUsersViewModel(administration: administration))
    }

    var body: some View {
        Form {
            Section("ユーザーを追加") {
                TextField("ユーザーID", text: $viewModel.newUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("パスワード（\(PasswordPolicy.minLength)〜\(PasswordPolicy.maxLength)文字）", text: $viewModel.newPassword)
                TextField("表示名（任意）", text: $viewModel.newDisplayName)
                Picker("ロール", selection: $viewModel.newRole) {
                    Text(Role.user.rawValue).tag(Role.user.rawValue)
                    Text(Role.admin.rawValue).tag(Role.admin.rawValue)
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
                            Text("\(user.username) / \(user.role.rawValue)")
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.inkTertiary)
                        }
                        Spacer()
                        // 自分自身のロール変更・削除はさせない（自己ロックアウト防止。
                        // サーバー側でも最後の admin は 409 で保護される）。
                        if user.canChangeRoleOrDelete {
                            Button(user.role.isAdmin ? "user へ" : "admin へ") {
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
