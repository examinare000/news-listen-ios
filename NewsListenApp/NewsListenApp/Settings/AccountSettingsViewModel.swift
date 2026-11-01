//
//  AccountSettingsViewModel.swift
//  NewsListenApp
//
//  アカウント画面の表示名の保存とパスワード変更の状態・文言。通信は `AccountProfile` に任せる。
//  入力の下書きは View の @State のままで、操作の引数として受ける。
//

import Combine
import Foundation

@MainActor
final class AccountSettingsViewModel: ObservableObject {
    /// 操作結果のフィードバック文言。
    @Published private(set) var message: String?
    @Published private(set) var isSubmitting = false

    /// View の生成時に組んだ手順。`nil` は通信手段が無いとき。寿命の間差し替えない。
    private let profile: AccountProfile?

    init(profile: AccountProfile?) {
        self.profile = profile
    }

    /// 表示名を保存し、確定した主体で現在の主体を更新する。
    ///
    /// 前の主体の応答が次の主体の payload を書き換えないよう、await の前に stamp を捕捉し
    /// （最初の await より前・独立した文: ios-slice-auth-01）、await の後は照合付きで書く。
    func saveProfile(displayName: String, appState: AppState) async {
        let stamp = appState.subjectStamp
        guard let profile else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let updated = try await profile.updateDisplayName(displayName)
            appState.updateCurrentSubject(updated, capturedAt: stamp)
            message = "表示名を更新しました"
        } catch {
            message = "表示名の更新に失敗しました"
        }
    }

    /// 現在パスワードを検証して新パスワードへ変更する。成功なら `true`（View が下書きを空にする）。
    func changePassword(current: String, new: String, appState: AppState) async -> Bool {
        if case .failure = PasswordPolicy.validate(new) {
            message = Self.lengthViolationMessage
            return false
        }
        guard let profile else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await profile.changePassword(current: current, new: new)
            message = "パスワードを変更しました"
            return true
        } catch AccountProfileFailure.currentPasswordRejected {
            message = "現在のパスワードが正しくありません"
        } catch AccountProfileFailure.policyViolation {
            message = Self.lengthViolationMessage
        } catch {
            message = "パスワード変更に失敗しました"
        }
        return false
    }

    private static let lengthViolationMessage =
        "新しいパスワードは\(PasswordPolicy.minLength)〜\(PasswordPolicy.maxLength)文字にしてください"
}
