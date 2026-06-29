//
//  LoginView.swift
//  NewsListenApp
//
//  接続設定の後、未ログイン時に表示するログイン画面。
//

import SwiftUI

// ASAuthorizationPasskeyProvider は Passkey モジュール内で AuthenticationServices を内部に閉じるため、
// LoginView は Passkey モジュールのシンボルのみを参照。
// 直接 AuthenticationServices を import しない（参照は ASAuthorizationPasskeyProvider に限定）。

/// ログイン画面。ユーザー ID とパスワード、または Passkey でログインする。
struct LoginView: View {
    /// ユーザーID・パスワードログインを担う ViewModel。
    @StateObject private var viewModel: LoginViewModel
    /// Passkey ログインを担う ViewModel。
    @StateObject private var passkeyViewModel: PasskeyLoginViewModel

    /// - Parameters:
    ///   - apiClient: ログイン通信に使うクライアント。
    ///   - onSuccess: ログイン成功時のコールバック（通常 `AppState.completeLogin`）。
    init(apiClient: APIClient, onSuccess: @escaping (LoginResponse) -> Void) {
        _viewModel = StateObject(wrappedValue: LoginViewModel(apiClient: apiClient, onSuccess: onSuccess))
        _passkeyViewModel = StateObject(wrappedValue: PasskeyLoginViewModel(
            apiClient: apiClient,
            provider: ASAuthorizationPasskeyProvider(),
            onSuccess: onSuccess
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: DSSpacing.s) {
                        Text("News Listen")
                            .font(DSFont.display)
                            .foregroundStyle(DSColor.ink)
                        Text("読んで、聴いて、英語を")
                            .dsEyebrow()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSSpacing.l)
                    .listRowBackground(Color.clear)
                }

                Section("ログイン") {
                    TextField("ユーザーID", text: $viewModel.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("パスワード", text: $viewModel.password)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }

                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Text("ログイン")
                    }
                }
                .disabled(!viewModel.canSubmit)

                Section("別のログイン方法") {
                    Button {
                        Task { await passkeyViewModel.performLogin() }
                    } label: {
                        if passkeyViewModel.isRunning {
                            ProgressView()
                        } else {
                            Text("Passkey でログイン")
                        }
                    }
                    .disabled(passkeyViewModel.isRunning)

                    if let error = passkeyViewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
            .navigationTitle("ログイン")
        }
    }
}
