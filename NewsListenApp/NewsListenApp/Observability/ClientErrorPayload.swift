//
//  ClientErrorPayload.swift
//  NewsListenApp
//
//  クライアントのエラー/クラッシュ報告ペイロード（issue #83）。
//  backend POST /client-errors の ClientErrorReport に対応する。
//

import Foundation

/// クライアントエラー報告。backend の構造化ログ → Cloud Logging に集約される。
/// 機微情報は backend の scrub() が送出時に伏せるが、クライアント側でも PII を載せない方針。
struct ClientErrorPayload: Codable, Equatable {
    /// 送信元（"ios"）。
    let source: String
    /// エラー種別（"crash" 等）。
    let kind: String
    /// エラーメッセージ（任意）。
    let message: String?
    /// 付加情報（任意・String 値のみ）。
    let context: [String: String]?
}
