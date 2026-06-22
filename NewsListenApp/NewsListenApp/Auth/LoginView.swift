//
//  LoginView.swift
//  NewsListenApp
//
//  接続設定の後、未ログイン時に表示するログイン画面。
//

import SwiftUI

/// ログイン画面。ユーザー ID とパスワードでログインする。
struct LoginView: View {
    /// ログイン処理を担う ViewModel。
    @StateObject private var viewModel: LoginViewModel

    /// - Parameters:
    ///   - apiClient: ログイン通信に使うクライアント。
    ///   - onSuccess: ログイン成功時のコールバック（通常 `AppState.completeLogin`）。
    init(apiClient: APIClient, onSuccess: @escaping (LoginResponse) -> Void) {
        _viewModel = StateObject(wrappedValue: LoginViewModel(apiClient: apiClient, onSuccess: onSuccess))
    }

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("ログイン")
        }
    }
}
