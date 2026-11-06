//
//  DeviceSessions.swift
//  NewsListenApp
//
//  端末のセッション（ログイン中のデバイス）の一覧と失効。一覧は保持しない。
//

import Foundation

struct DeviceSession: Identifiable, Equatable {
    let id: String
    let deviceLabel: String?
    let createdAt: String
    let lastUsedAt: String?
    let isCurrent: Bool
}

@MainActor
final class DeviceSessions {
    private let gateway: AccountGateway

    init(gateway: AccountGateway) {
        self.gateway = gateway
    }

    func list() async throws -> [DeviceSession] {
        try await gateway.listSessions()
    }

    /// 失効済み（404）は成功として扱う。冪等（ios-rule-account-06）。
    func revoke(id: String) async throws {
        do {
            try await gateway.revokeSession(id)
        } catch ApiFailure.notFound(subject: .session) {
            return
        }
    }

    func revokeOthers() async throws -> Int {
        try await gateway.revokeOtherSessions()
    }
}
