//
//  PasswordPolicy.swift
//  NewsListenApp
//
//  パスワードの長さの規則（ADR-101）。規則の実体はここだけに置き、ほかの層は結果と公開値を使う。
//

import Foundation

/// 長さの違反。値は公開値（`PasswordPolicy.minLength`・`maxLength`）と同じ。
enum PasswordPolicyViolation: Error, Equatable {
    case tooShort(minimum: Int)
    case tooLong(maximum: Int)
}

enum PasswordPolicy {
    /// 案内文と文言はこの値から作る。比較の行は数値の literal で書く（ios-dec-79）。
    static let minLength = 12
    static let maxLength = 20

    static func validate(_ password: String) -> Result<Void, PasswordPolicyViolation> {
        guard password.count >= 12 else { return .failure(.tooShort(minimum: minLength)) }
        guard password.count <= 20 else { return .failure(.tooLong(maximum: maxLength)) }
        return .success(())
    }
}
