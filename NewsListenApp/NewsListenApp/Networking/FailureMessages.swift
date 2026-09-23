//
//  FailureMessages.swift
//  NewsListenApp
//
//  `ApiFailure` の利用者向け文言を組み立てる唯一の窓口（Spec §2.5 D4）。
//  VM / View は `ApiFailure` に `localizedDescription` を適用せず、必ずここを経由する
//  （経路 E1・11 箇所。order 完了条件 5 / order.md:94）。
//

import Foundation

/// 文言を表示する画面群の分類（S1 で実在する呼出元。feed 2 / starred 2 / settings 4 / podcast 3）。
///
/// SG-S1-2 = (b) では context によって文言は変わらない。context 別の文言が将来必要になっても
/// 変更は本ファイルの表と対応テストだけで済み、呼出側は変えなくてよい（spec §2.5）。
enum FailureContext {
    case feed, starred, settings, podcast
}

/// `ApiFailure` の利用者向け文言を返す。
///
/// 文言の中身は既存文言の移設のみで、新しい文言は作らない（order.md:59-64 の user 決定）。
enum FailureMessages {
    static func message(for failure: ApiFailure, context: FailureContext) -> String {
        switch failure {
        case .network(let error):
            return error.localizedDescription
        case .rateLimited:
            return "リクエストが多すぎます。しばらくしてからお試しください。"
        case .unauthorized:
            return "HTTP Error 401"
        case .forbidden:
            return "HTTP Error 403"
        case .notFound:
            return "HTTP Error 404"
        case .conflict:
            return "HTTP Error 409"
        case .validation:
            return "HTTP Error 400"
        case .server(let status):
            return "HTTP Error \(status)"
        case .unknown(let status):
            return "HTTP Error \(status)"
        case .decoding:
            // underlying を保持しないため詳細が落ちる（user 承認済みの文言差異。order.md:63）。
            return "Decoding error"
        }
    }
}
