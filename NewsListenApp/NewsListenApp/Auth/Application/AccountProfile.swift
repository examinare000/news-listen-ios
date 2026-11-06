//
//  AccountProfile.swift
//  NewsListenApp
//
//  表示名の更新とパスワード変更の手順。通信は port（`AccountGateway`）の向こうに置く。
//  `AccountGateway` は Account の周辺（ログイン・端末のセッション・Passkey・管理者）の port も束ねる。
//

import Foundation

/// Account の周辺の port。実体は adapter が組む。
struct AccountGateway {
    let updateProfile: (String) async throws -> Subject
    let changePassword: (String, String) async throws -> Void
    let login: (String, String) async throws -> LoginReceipt
    let listSessions: () async throws -> [DeviceSession]
    let revokeSession: (String) async throws -> Void
    let revokeOtherSessions: () async throws -> Int
    let passkeyRegisterOptions: () async throws -> (challengeID: String, options: PasskeyRegistrationOptions)
    let passkeyRegisterVerify: (String, PasskeyRegistrationCredential) async throws -> Void
    let passkeyLoginOptions: () async throws -> (challengeID: String, options: PasskeyAssertionOptions)
    let passkeyLoginVerify: (String, PasskeyAssertionCredential) async throws -> LoginReceipt
    let listPasskeyCredentials: () async throws -> [PasskeyCredential]
    let deletePasskeyCredential: (String) async throws -> Void
    let listUsers: () async throws -> [Subject]
    let createUser: (String, String, String?, Role) async throws -> Void
    let updateUserRole: (String, Role) async throws -> Void
    let deleteUser: (String) async throws -> Void
}

enum AccountProfileFailure: Error, Equatable {
    case policyViolation(PasswordPolicyViolation)
    /// 現在のパスワードが拒否された。
    case currentPasswordRejected
    case api(ApiFailure)
}

@MainActor
final class AccountProfile {
    private let gateway: AccountGateway

    init(gateway: AccountGateway) {
        self.gateway = gateway
    }

    /// 確定した `Subject` を返す。書き込みと主体の照合は呼ぶ側が行う。
    func updateDisplayName(_ name: String) async throws -> Subject {
        do {
            return try await gateway.updateProfile(name)
        } catch let failure as ApiFailure {
            throw AccountProfileFailure.api(failure)
        }
    }

    /// 長さの規則を先に検査し、違反なら通信しない。
    func changePassword(current: String, new: String) async throws {
        if case .failure(let violation) = PasswordPolicy.validate(new) {
            throw AccountProfileFailure.policyViolation(violation)
        }
        do {
            try await gateway.changePassword(current, new)
        } catch ApiFailure.validation {
            throw AccountProfileFailure.currentPasswordRejected
        } catch let failure as ApiFailure {
            throw AccountProfileFailure.api(failure)
        }
    }
}
