//
//  PasskeyEnrollment.swift
//  NewsListenApp
//
//  Passkey の登録・一覧・削除の手順。
//

import Foundation

struct PasskeyCredential: Identifiable, Equatable {
    let id: String
    let name: String?
    let createdAt: String
}

enum PasskeyEnrollmentFailure: Error, Equatable {
    case alreadyRegistered
}

@MainActor
final class PasskeyEnrollment {
    private let gateway: AccountGateway
    private let provider: PasskeyAuthorizationProviding

    init(gateway: AccountGateway, provider: PasskeyAuthorizationProviding) {
        self.gateway = gateway
        self.provider = provider
    }

    func credentials() async throws -> [PasskeyCredential] {
        try await gateway.listPasskeyCredentials()
    }

    /// 画面は options の 409 でも「登録済み」の文言を出すので、flow 全体を 1 つの `do` で包む。
    func register() async throws {
        do {
            let (challengeID, options) = try await gateway.passkeyRegisterOptions()
            let credential = try await provider.createCredential(options)
            try await gateway.passkeyRegisterVerify(challengeID, credential)
        } catch ApiFailure.conflict {
            throw PasskeyEnrollmentFailure.alreadyRegistered
        }
    }

    /// 削除済み（404）は成功として扱う。冪等（ios-rule-account-06）。
    func delete(id: String) async throws {
        do {
            try await gateway.deletePasskeyCredential(id)
        } catch ApiFailure.notFound(subject: .credential) {
            return
        }
    }
}
