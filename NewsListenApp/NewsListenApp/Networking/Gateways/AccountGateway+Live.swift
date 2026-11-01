//
//  AccountGateway+Live.swift
//  NewsListenApp
//
//  表示名の更新とパスワード変更の port を `APIClient` から組む adapter。応答は `Subject` に変換して返す。
//

import Foundation

extension AccountGateway {
    static func live(apiClient: APIClient) -> AccountGateway {
        AccountGateway(
            updateProfile: { name in
                try await apiClient.updateProfile(displayName: name).toSubject()
            },
            changePassword: { current, new in
                try await apiClient.changePassword(current: current, new: new)
            }
        )
    }
}
