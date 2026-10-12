//
//  ApiFailure.swift
//  NewsListenApp
//
//  API 通信の失敗の意味を表す共有の domain 型。
//

import Foundation

/// 宣言のある 404 が指す対象（意味の無い 404 と区別する。Spec §2.1 D3）。
///
/// - `streak` / `quota` / `quiz`: 旧 backend または機能未提供。
/// - `credential` / `session` / `star`: 冪等削除・冪等失効が既に完了している。
enum NotFoundSubject: Equatable {
    case streak, quota, quiz
    case credential, session, star
}

/// API 通信の失敗を表す値（Spec §2.1）。値集合はここに列挙した 10 case のみで、追加しない。
///
/// `LocalizedError` には適合させない。適合させると `localizedDescription` 経由で文言を得る経路が
/// 残り、文言の所有者が `FailureMessages` 1 箇所に定まらなくなる（order 完了条件 5）。
enum ApiFailure: Error, Equatable {
    case network(URLError)
    case unauthorized
    case forbidden
    case notFound(subject: NotFoundSubject)
    case conflict
    case rateLimited(retryAfter: Int?)
    case validation
    case server(status: Int)
    case decoding
    case unknown(status: Int)
}
