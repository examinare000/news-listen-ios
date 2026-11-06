//
//  PasskeySignIn.swift
//  NewsListenApp
//
//  Passkey によるログインの手順: options 取得 → 認証器 → verify。
//

import Foundation

@MainActor
final class PasskeySignIn {
    private let gateway: AccountGateway
    private let provider: PasskeyAuthorizationProviding

    init(gateway: AccountGateway, provider: PasskeyAuthorizationProviding) {
        self.gateway = gateway
        self.provider = provider
    }

    func signIn() async throws -> LoginReceipt {
        let (challengeID, options) = try await gateway.passkeyLoginOptions()
        let credential = try await provider.assertCredential(options)
        return try await gateway.passkeyLoginVerify(challengeID, credential)
    }
}
