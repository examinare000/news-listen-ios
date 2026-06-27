//
//  Base64URL.swift
//  NewsListenApp
//
//  WebAuthn バイナリ転送の標準形式。パディング無し・URL セーフ（'-', '_'）な base64url 変換。
//  RFC 4648 §5 準拠。Foundation のみ依存（純粋関数）。
//

import Foundation

extension Data {

    /// base64url 文字列（パディング無し・URL セーフ）から `Data` を生成する。
    ///
    /// - Parameter string: パディング無し base64url 文字列（'-', '_' を URL-safe 文字として扱う）。
    /// - Returns: デコードされたデータ。不正な入力の場合は `nil`。
    init?(base64URLEncoded string: String) {
        // URL-safe → standard base64 に戻す。
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 4 の倍数になるようパディングを補う（RFC 4648 はパディングを任意とする）。
        let remainder = s.count % 4
        if remainder != 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }

    /// `Data` を base64url 文字列（パディング無し・URL セーフ）に変換する。
    ///
    /// - Returns: パディング '=' を除去し、'+' → '-', '/' → '_' に置換した文字列。
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
