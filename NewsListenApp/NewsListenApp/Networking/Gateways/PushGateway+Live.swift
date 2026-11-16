//
//  PushGateway+Live.swift
//  NewsListenApp
//
//  端末トークンの登録の port を `APIClient` から組む adapter。
//

import Foundation

extension PushGateway {
    static func live(apiClient: APIClient) -> PushGateway {
        PushGateway(register: { @MainActor token in
            try await apiClient.registerDeviceToken(token)
        })
    }
}
