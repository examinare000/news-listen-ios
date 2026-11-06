//
//  PasskeyRegistrationViewModel.swift
//  NewsListenApp
//
//  Passkey 登録フローのロジック。設定画面から呼ぶ。
//  手順は PasskeyEnrollment（use case）に任せ、状態と文言だけを持つ。
//

import Combine
import Foundation

/// Passkey 登録画面の状態と実行処理を担う ViewModel。
@MainActor
final class PasskeyRegistrationViewModel: ObservableObject {
    /// ユーザーに表示するエラー文言（なければ nil）。キャンセル時は設定しない。
    @Published private(set) var errorMessage: String?
    /// 処理実行中フラグ。
    @Published private(set) var isRunning = false

    private let enrollment: PasskeyEnrollment
    private let onSuccess: () -> Void

    /// - Parameters:
    ///   - enrollment: Passkey の登録・一覧・削除の手順。
    ///   - onSuccess: 登録成功時のコールバック（UI 更新・一覧リロード等は呼び出し側が担う）。
    init(enrollment: PasskeyEnrollment, onSuccess: @escaping () -> Void = {}) {
        self.enrollment = enrollment
        self.onSuccess = onSuccess
    }

    /// Passkey 登録フローを実行する。
    func register() async {
        isRunning = true
        errorMessage = nil
        do {
            try await enrollment.register()
            isRunning = false
            onSuccess()
        } catch PasskeyError.canceled {
            // キャンセルは失敗扱いしない。
            isRunning = false
        } catch PasskeyEnrollmentFailure.alreadyRegistered {
            // 既登録クレデンシャルには専用メッセージを表示する（バックエンド仕様通り）。
            errorMessage = "この Passkey はすでに登録されています"
            isRunning = false
        } catch {
            errorMessage = "Passkey の登録に失敗しました"
            isRunning = false
        }
    }
}
