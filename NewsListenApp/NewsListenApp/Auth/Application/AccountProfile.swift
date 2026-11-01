//
//  AccountProfile.swift
//  NewsListenApp
//
//  表示名の更新とパスワード変更の手順。通信は port（`AccountGateway`）の向こうに置く。
//

import Foundation

/// 表示名の更新とパスワード変更の port。実体は adapter が組む。
struct AccountGateway {
    let updateProfile: (String) async throws -> Subject
    let changePassword: (String, String) async throws -> Void
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
