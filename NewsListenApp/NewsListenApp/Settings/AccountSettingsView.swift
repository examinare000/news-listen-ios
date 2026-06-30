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
    /// ログイン中のデバイス（セッション）を担う ViewModel（issue #84）。
    @StateObject private var sessionsViewModel: SessionsViewModel

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
    /// 「他のデバイスからログアウト」確認ダイアログの表示状態（issue #84）。
    @State private var showRevokeOthersConfirm = false

    /// ビューを生成する。
    /// - Parameter apiClient: Passkey 操作に使うクライアント。未設定時は `nil`。
    init(apiClient: APIClient?) {
        // ViewModel は Optional な apiClient を受け取り、内部で guard で保護する。
        _registrationViewModel = StateObject(wrappedValue: PasskeyRegistrationViewModel(
            apiClient: apiClient,
            provider: ASAuthorizationPasskeyProvider()
        ))
        _credentialsViewModel = StateObject(wrappedValue: PasskeyCredentialsViewModel(apiClient: apiClient))
        _sessionsViewModel = StateObject(wrappedValue: SessionsViewModel(apiClient: apiClient))
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
                Text(message).font(DSFont.footnote).foregroundStyle(DSColor.inkSecondary)
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
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.inkSecondary)
                        }
                    } else {
                        Text("登録済み Passkey はありません")
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.inkSecondary)
                    }
                } else {
                    ForEach(credentialsViewModel.credentials) { credential in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credential.name ?? "（名前なし）")
                                    .font(DSFont.body)
                                    .foregroundStyle(DSColor.ink)
                                Text("登録日: \(extractDate(credential.createdAt))")
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.inkTertiary)
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
                        .foregroundStyle(DSColor.danger)
                        .font(DSFont.footnote)
                }
            }
            .sheet(isPresented: $showPasskeyRegistration) {
                passkeyRegistrationSheet
            }
            .task {
                await credentialsViewModel.loadCredentials()
            }

            // ログイン中のデバイス（issue #84）
            sessionsSection
        }
    }

    /// ログイン中のデバイス（セッション）一覧・個別/一括失効セクション。
    @ViewBuilder
    private var sessionsSection: some View {
        Section("ログイン中のデバイス") {
            // 他のデバイスからログアウト（現在以外が無ければ無効）。
            Button("他のデバイスからログアウト", role: .destructive) {
                showRevokeOthersConfirm = true
            }
            .disabled(sessionsViewModel.sessions.filter { !$0.current }.isEmpty)

            if sessionsViewModel.sessions.isEmpty {
                if sessionsViewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8, anchor: .center)
                        Text("読み込み中…").font(DSFont.caption).foregroundStyle(DSColor.inkSecondary)
                    }
                } else {
                    Text("ログイン中のデバイスはありません")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.inkSecondary)
                }
            } else {
                ForEach(sessionsViewModel.sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(session.deviceLabel ?? "不明なデバイス")
                                    .font(DSFont.body)
                                    .foregroundStyle(DSColor.ink)
                                if session.current {
                                    Text("現在のデバイス")
                                        .font(DSFont.caption)
                                        .foregroundStyle(DSColor.inkSecondary)
                                }
                            }
                            Text(sessionDateLine(session))
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.inkTertiary)
                        }
                        Spacer()
                        // 現在のデバイスはこの画面から失効しない（＝ログアウト操作）。
                        if !session.current {
                            Button(role: .destructive) {
                                Task { await sessionsViewModel.revokeSession(id: session.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("デバイスをログアウト: \(session.deviceLabel ?? "不明なデバイス")")
                        }
                    }
                }
            }

            if let error = sessionsViewModel.errorMessage {
                Text(error).foregroundStyle(DSColor.danger).font(DSFont.footnote)
            }
            if let count = sessionsViewModel.revokedOthersCount {
                Text("他の \(count) 台のデバイスからログアウトしました")
                    .foregroundStyle(DSColor.inkSecondary)
                    .font(DSFont.footnote)
            }
        }
        .task {
            await sessionsViewModel.loadSessions()
        }
        .confirmationDialog(
            "他のデバイスからログアウトしますか？",
            isPresented: $showRevokeOthersConfirm,
            titleVisibility: .visible
        ) {
            Button("ログアウト", role: .destructive) {
                Task { await sessionsViewModel.revokeOthers() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("現在のデバイス以外のすべてのセッションが失効します。")
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
                                .font(DSFont.body)
                        }
                    } else {
                        Text("デバイスで新しい Passkey を登録します。")
                            .font(DSFont.body)
                        Button("登録を開始") {
                            Task { await registrationViewModel.register() }
                        }
                    }

                    if let error = registrationViewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(DSColor.danger)
                            .font(DSFont.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
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

    /// セッション行の日付表記（ログイン日 + 最終利用日があれば併記・issue #84 review）。
    private func sessionDateLine(_ session: SessionItem) -> String {
        var line = "ログイン: \(extractDate(session.createdAt))"
        if let lastUsed = session.lastUsedAt {
            line += "　最終利用: \(extractDate(lastUsed))"
        }
        return line
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
