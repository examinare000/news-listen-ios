//
//  AccountSettingsView.swift
//  NewsListenApp
//
//  設定画面の「アカウント」セクション。プロフィール（表示名）編集・パスワード変更・
//  ログアウト、および管理者にはユーザー管理画面への導線を提供する。
//  また Passkey 登録・管理の導線も提供する。
//

import SwiftUI

/// 設定 Form 内に配置するアカウント管理セクション。
struct AccountSettingsView: View {
    /// アプリ全体で共有する設定・認証状態。
    @EnvironmentObject private var appState: AppState
    /// Passkey 登録を担う ViewModel。
    @StateObject private var registrationViewModel: PasskeyRegistrationViewModel
    /// Passkey クレデンシャル一覧を担う ViewModel。
    @StateObject private var credentialsViewModel: PasskeyCredentialsViewModel

    /// 入力中の表示名。
    @State private var displayName = ""
    /// 入力中の現在パスワード。
    @State private var currentPassword = ""
    /// 入力中の新パスワード。
    @State private var newPassword = ""
    /// 操作結果のフィードバック文言。
    @State private var message: String?
    /// Passkey 登録シートの表示状態。
    @State private var showPasskeyRegistration = false

    /// ビューを生成する。
    /// - Parameter apiClient: Passkey 操作に使うクライアント。未設定時は `nil`。
    init(apiClient: APIClient?) {
        // ViewModel は Optional な apiClient を受け取り、内部で guard で保護する。
        _registrationViewModel = StateObject(wrappedValue: PasskeyRegistrationViewModel(
            apiClient: apiClient,
            provider: ASAuthorizationPasskeyProvider()
        ))
        _credentialsViewModel = StateObject(wrappedValue: PasskeyCredentialsViewModel(apiClient: apiClient))
    }

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

        // Passkey 管理セクション（ログイン済みで API クライアント有効時のみ表示）
        if appState.apiClient != nil {
            Section("Passkey") {
                // 登録ボタン
                Button("Passkey を登録") { showPasskeyRegistration = true }

                // 登録済み Passkey 一覧と削除
                if credentialsViewModel.credentials.isEmpty {
                    if credentialsViewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8, anchor: .center)
                            Text("読み込み中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("登録済み Passkey はありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(credentialsViewModel.credentials) { credential in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credential.name ?? "（名前なし）")
                                    .font(.body)
                                Text("登録日: \(extractDate(credential.createdAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    await credentialsViewModel.deleteCredential(id: credential.credentialID)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if let error = credentialsViewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .sheet(isPresented: $showPasskeyRegistration) {
                passkeyRegistrationSheet
            }
            .task {
                await credentialsViewModel.loadCredentials()
            }
        }
    }

    /// Passkey 登録シート。
    private var passkeyRegistrationSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if registrationViewModel.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8, anchor: .center)
                            Text("Passkey を登録しています…")
                                .font(.body)
                        }
                    } else {
                        Text("デバイスで新しい Passkey を登録します。")
                            .font(.body)
                        Button("登録を開始") {
                            Task { await registrationViewModel.register() }
                        }
                    }

                    if let error = registrationViewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Passkey を登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !registrationViewModel.isRunning {
                        Button("キャンセル") { showPasskeyRegistration = false }
                    }
                }
            }
            .onChange(of: registrationViewModel.isRunning) { _, newValue in
                // 登録完了後（isRunning が false に戻る）、シートを閉じて一覧をリロード
                if !newValue && registrationViewModel.errorMessage == nil {
                    showPasskeyRegistration = false
                    Task { await credentialsViewModel.loadCredentials() }
                }
            }
        }
    }

    /// ISO 8601 文字列から "YYYY-MM-DD" 形式を抽出する。
    /// 例: "2025-06-26T12:34:56Z" → "2025-06-26"
    private func extractDate(_ isoString: String) -> String {
        String(isoString.prefix(10))
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
