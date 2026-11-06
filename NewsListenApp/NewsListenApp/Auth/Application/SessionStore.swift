//
//  SessionStore.swift
//  NewsListenApp
//
//  セッショントークンの保管の port。実体は adapter（Keychain・インメモリ）が持つ。
//

import Foundation

/// セッショントークンの読み書きを抽象化する。
protocol SessionStore: AnyObject {
    /// 保存中のセッショントークン。`nil` 代入で削除する。
    var token: String? { get set }
}
