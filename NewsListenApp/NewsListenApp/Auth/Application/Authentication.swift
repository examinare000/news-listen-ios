//
//  Authentication.swift
//  NewsListenApp
//
//  パスワードによるログインの手順。通信は port（`AccountGateway`）の向こうに置く。
//

import Foundation

/// ログイン成功の結果（ios-cmd-account-01 の receipt）。`AppState.completeLogin` へ渡す。
struct LoginReceipt: Equatable {
    let token: String
    let subject: Subject
}

@MainActor
final class Authentication {
    private let gateway: AccountGateway

    init(gateway: AccountGateway) {
        self.gateway = gateway
    }

    func login(username: String, password: String) async throws -> LoginReceipt {
        try await gateway.login(username, password)
    }
}
