//
//  LoginView.swift
//  NewsListenApp
//
//  接続設定の後、未ログイン時に表示するログイン画面。
//

import SwiftUI

/// ログイン画面。ユーザー ID とパスワード、または Passkey でログインする。
struct LoginView: View {
    /// ユーザーID・パスワードログインを担う ViewModel。
    @StateObject private var viewModel: LoginViewModel
    /// Passkey ログインを担う ViewModel。
    @StateObject private var passkeyViewModel: PasskeyLoginViewModel

    /// - Parameters:
    ///   - authentication: パスワードログインの手順。
    ///   - passkeySignIn: Passkey ログインの手順。
    ///   - onSuccess: ログイン成功時のコールバック（通常 `AppState.completeLogin`）。
    init(authentication: Authentication, passkeySignIn: PasskeySignIn, onSuccess: @escaping (LoginReceipt) -> Void) {
        _viewModel = StateObject(wrappedValue: LoginViewModel(authentication: authentication, onSuccess: onSuccess))
        _passkeyViewModel = StateObject(wrappedValue: PasskeyLoginViewModel(signIn: passkeySignIn, onSuccess: onSuccess))
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
                        .foregroundStyle(DSColor.danger)
                        .font(DSFont.footnote)
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
                            .foregroundStyle(DSColor.danger)
                            .font(DSFont.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
            .navigationTitle("ログイン")
        }
    }
}

#if DEBUG
#Preview("Login / Light") {
    LoginView(authentication: PreviewSamples.authentication(), passkeySignIn: PreviewSamples.passkeySignIn(), onSuccess: { _ in })
}

#Preview("Login / Dark") {
    LoginView(authentication: PreviewSamples.authentication(), passkeySignIn: PreviewSamples.passkeySignIn(), onSuccess: { _ in })
        .preferredColorScheme(.dark)
}
#endif
