//
//  UserAdministration.swift
//  NewsListenApp
//
//  管理者のユーザー管理。自分の行の判定とパスワードの長さの検査をここに置く。
//

import Foundation

struct ManagedUser: Identifiable, Equatable {
    let username: String
    let displayName: String
    let role: Role
    let canChangeRoleOrDelete: Bool
    var id: String { username }
}

enum UserAdministrationFailure: Error, Equatable {
    case policyViolation(PasswordPolicyViolation)
    case api(ApiFailure)
}

@MainActor
final class UserAdministration {
    private let gateway: AccountGateway
    private let currentUsername: () -> String?

    init(gateway: AccountGateway, currentUsername: @escaping () -> String?) {
        self.gateway = gateway
        self.currentUsername = currentUsername
    }

    /// 行の可否は一覧を取得した時点の主体で決める（ios-dec-107）。
    func users() async throws -> [ManagedUser] {
        let subjects = try await gateway.listUsers()
        let current = currentUsername()
        return subjects.map {
            ManagedUser(username: $0.username, displayName: $0.displayName, role: $0.role, canChangeRoleOrDelete: $0.username != current)
        }
    }

    /// 長さの規則を先に検査し、違反なら通信しない。空の表示名は送らない。
    func create(username: String, password: String, displayName: String, role: Role) async throws {
        if case .failure(let violation) = PasswordPolicy.validate(password) {
            throw UserAdministrationFailure.policyViolation(violation)
        }
        do {
            try await gateway.createUser(username, password, displayName.isEmpty ? nil : displayName, role)
        } catch let failure as ApiFailure {
            throw UserAdministrationFailure.api(failure)
        }
    }

    func delete(username: String) async throws {
        do {
            try await gateway.deleteUser(username)
        } catch let failure as ApiFailure {
            throw UserAdministrationFailure.api(failure)
        }
    }

    func setRole(username: String, role: Role) async throws {
        do {
            try await gateway.updateUserRole(username, role)
        } catch let failure as ApiFailure {
            throw UserAdministrationFailure.api(failure)
        }
    }
}
