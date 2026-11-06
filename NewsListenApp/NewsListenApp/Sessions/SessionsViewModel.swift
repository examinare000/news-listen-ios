//
//  SessionsViewModel.swift
//  NewsListenApp
//
//  ログイン中のデバイス/セッション一覧・個別失効・一括失効のロジック（issue #84）。
//  手順は DeviceSessions（use case）に任せ、状態と文言だけを持つ。
//

import Combine
import Foundation

/// ログイン中のデバイス（セッション）画面の状態と操作を担う ViewModel。
@MainActor
final class SessionsViewModel: ObservableObject {
    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 一括失効した件数のフィードバック（なければ nil）。
    @Published private(set) var revokedOthersCount: Int?

    private let deviceSessions: DeviceSessions

    init(deviceSessions: DeviceSessions) {
        self.deviceSessions = deviceSessions
    }

    /// 有効セッション一覧をサーバから取得する。
    func loadSessions() async {
        isLoading = true
        errorMessage = nil
        revokedOthersCount = nil   // 再読み込み時に一括失効のフィードバックを消す。
        do {
            sessions = try await deviceSessions.list()
        } catch {
            errorMessage = "デバイス一覧の取得に失敗しました"
        }
        isLoading = false
    }

    /// 指定セッションを個別失効する。404（他人/不在）は use case が成功にする。
    func revokeSession(id: String) async {
        revokedOthersCount = nil   // 個別操作時は一括失効のフィードバックを消す。
        do {
            try await deviceSessions.revoke(id: id)
            sessions.removeAll { $0.id == id }
        } catch {
            errorMessage = "ログアウトに失敗しました"
        }
    }

    /// 現在以外のセッションを一括失効する（「他のデバイスからログアウト」）。
    func revokeOthers() async {
        do {
            revokedOthersCount = try await deviceSessions.revokeOthers()
            await loadSessions()
        } catch {
            errorMessage = "一括ログアウトに失敗しました"
        }
    }
}
