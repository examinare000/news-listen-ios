//
//  AccountGateway+Live.swift
//  NewsListenApp
//
//  Account の周辺（ログイン・表示名とパスワード・端末のセッション・Passkey・管理者）の port を
//  `APIClient` から組む adapter。応答は domain / リードモデルに変換して返す。
//

import Foundation

extension AccountGateway {
    static func live(apiClient: APIClient) -> AccountGateway {
        live(client: { apiClient })
    }

    /// - Parameter client: 呼出のたびに現在の `APIClient` を返す。nil のとき全 closure が
    ///   `ApiFailure.network(URLError(.badURL))` を投げる（UI からは届かない経路）。
    static func live(client: @escaping @MainActor () -> APIClient?) -> AccountGateway {
        let current: @MainActor () throws -> APIClient = {
            guard let resolved = client() else { throw ApiFailure.network(URLError(.badURL)) }
            return resolved
        }
        return AccountGateway(
            updateProfile: { @MainActor name in
                try await current().updateProfile(displayName: name).toSubject()
            },
            changePassword: { @MainActor currentPassword, new in
                try await current().changePassword(current: currentPassword, new: new)
            },
            login: { @MainActor username, password in
                try await current().login(username: username, password: password).toReceipt()
            },
            listSessions: { @MainActor in
                try await current().listSessions().sessions.map { $0.toDeviceSession() }
            },
            revokeSession: { @MainActor id in
                try await current().revokeSession(id: id)
            },
            revokeOtherSessions: { @MainActor in
                try await current().revokeOtherSessions().revokedCount
            },
            passkeyRegisterOptions: { @MainActor in
                let response = try await current().passkeyRegisterOptions()
                return try (response.challengeID, PasskeyOptionsDecoder.decodeRegistration(from: response))
            },
            passkeyRegisterVerify: { @MainActor challengeID, credential in
                try await current().passkeyRegisterVerify(
                    challengeID: challengeID,
                    credential: PasskeyCredentialEncoder.encodeRegistration(credential)
                )
            },
            passkeyLoginOptions: { @MainActor in
                let response = try await current().passkeyLoginOptions()
                return try (response.challengeID, PasskeyOptionsDecoder.decodeAssertion(from: response))
            },
            passkeyLoginVerify: { @MainActor challengeID, credential in
                try await current().passkeyLoginVerify(
                    challengeID: challengeID,
                    credential: PasskeyCredentialEncoder.encodeAssertion(credential)
                ).toReceipt()
            },
            listPasskeyCredentials: { @MainActor in
                try await current().listPasskeyCredentials().credentials.map { $0.toCredential() }
            },
            deletePasskeyCredential: { @MainActor id in
                try await current().deletePasskeyCredential(id: id)
            },
            listUsers: { @MainActor in
                try await current().listUsers().users.map { $0.toSubject() }
            },
            createUser: { @MainActor username, password, displayName, role in
                _ = try await current().createUser(username: username, password: password, displayName: displayName, role: role.rawValue)
            },
            updateUserRole: { @MainActor username, role in
                _ = try await current().updateUser(username: username, role: role.rawValue)
            },
            deleteUser: { @MainActor username in
                try await current().deleteUser(username: username)
            }
        )
    }
}
