//
//  SessionStore.swift
//  NewsListenApp
//
//  セッショントークンの保管抽象。本番は Keychain（機密情報は UserDefaults に置かない、
//  agent-rules/12 準拠）。テストは差し替え可能なインメモリ実装を注入する。
//

import Foundation
import Security

/// セッショントークンの読み書きを抽象化する。
protocol SessionStore: AnyObject {
    /// 保存中のセッショントークン。`nil` 代入で削除する。
    var token: String? { get set }
}

/// テスト用のインメモリ実装。Keychain に触れずに状態遷移を検証できる。
final class InMemorySessionStore: SessionStore {
    var token: String?
    init(token: String? = nil) { self.token = token }
}

/// Keychain（generic password）にセッショントークンを保管する実装。
///
/// 平文をログに出さないこと。UserDefaults と異なり端末ロックと連動し、バックアップ対象外にできる。
final class KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "nl_session"

    /// - Parameter service: Keychain の service 名（既定はアプリ固有値）。
    init(service: String = "com.newslisten.app.session") {
        self.service = service
    }

    var token: String? {
        get { read() }
        set {
            if let newValue, !newValue.isEmpty {
                write(newValue)
            } else {
                delete()
            }
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private func write(_ value: String) {
        let data = Data(value.utf8)
        // 既存があれば更新、無ければ追加（upsert）。
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
