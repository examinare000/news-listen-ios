//
//  PushRegistration.swift
//  NewsListenApp
//
//  プッシュ通知の端末トークンの登録と、通知のタップで選ばれたエピソードの保留。
//  通信は port（`PushGateway`）の向こうに置く。認証・主体の判定は closure で受ける。
//

import Foundation
import Combine

/// 端末トークンの登録の port。実体は adapter が組む。
struct PushGateway {
    let register: (String) async throws -> Void
}

@MainActor
final class PushRegistration: ObservableObject {
    /// 通知のタップで開く対象エピソード ID。未認証でも設定し、受け手が消費するまで残す。
    @Published private(set) var pendingEpisodeId: String?

    /// 取得済みの端末トークン（16 進）。主体のものではなく端末の値なので、離脱でも消さない。
    private var deviceToken: String?
    /// 登録の投げっぱなし Task。差し替えの前に cancel する。
    private var registrationTask: Task<Void, Never>?

    private let gateway: () -> PushGateway?
    private let isAuthenticated: () -> Bool
    private let subjectStamp: () -> SubjectStamp
    private let isCurrentSubject: (SubjectStamp) -> Bool

    init(
        gateway: @escaping () -> PushGateway?,
        isAuthenticated: @escaping () -> Bool,
        subjectStamp: @escaping () -> SubjectStamp,
        isCurrentSubject: @escaping (SubjectStamp) -> Bool
    ) {
        self.gateway = gateway
        self.isAuthenticated = isAuthenticated
        self.subjectStamp = subjectStamp
        self.isCurrentSubject = isCurrentSubject
    }

    /// 端末トークンを保持し、登録を予約する。前の予約は cancel する。
    func didReceiveDeviceToken(_ token: String) {
        deviceToken = token
        scheduleRegistration()
    }

    /// 登録を予約して完了を待つ。認証済みの間だけ送り、失敗は握りつぶす（best-effort）。
    func registerIfPossible() async {
        await scheduleRegistration().value
    }

    /// 予約済みの登録を cancel する。端末トークンは消さない。
    func cancelPendingRegistration() {
        registrationTask?.cancel()
    }

    func openEpisode(id: String) {
        pendingEpisodeId = id
    }

    /// 保留中の id が `id` と同じときだけ消す。消費の await 中に別の通知が来ても、その id を消さない。
    func consumePendingEpisode(id: String) {
        if pendingEpisodeId == id { pendingEpisodeId = nil }
    }

    @discardableResult
    private func scheduleRegistration() -> Task<Void, Never> {
        registrationTask?.cancel()
        let stamp = subjectStamp()
        let task = Task { await send(stamp: stamp) }
        registrationTask = task
        return task
    }

    /// logout の cancel と主体の交代が、送信の直前に効くように、すべての条件をここで確かめる。
    private func send(stamp: SubjectStamp) async {
        guard isAuthenticated(), isCurrentSubject(stamp),
              let token = deviceToken, !Task.isCancelled,
              let gateway = gateway() else { return }
        _ = try? await gateway.register(token)
    }
}
