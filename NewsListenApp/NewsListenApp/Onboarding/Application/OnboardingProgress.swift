//
//  OnboardingProgress.swift
//  NewsListenApp
//
//  初回 Onboarding の完了の状態と記録（application）。完了の正本はサーバー。
//

import Foundation
import Combine

@MainActor
final class OnboardingProgress: ObservableObject {
    /// `nil` = 未取得（判定保留）。`false` のときだけ Onboarding を出す。
    @Published private(set) var isCompleted: Bool?

    private let fetchStatus: () async throws -> Bool?
    private let recordCompleted: () async throws -> Void
    private let subjectStamp: () -> SubjectStamp
    private let isCurrentSubject: (SubjectStamp) -> Bool

    init(
        fetchStatus: @escaping () async throws -> Bool?,
        recordCompleted: @escaping () async throws -> Void,
        subjectStamp: @escaping () -> SubjectStamp,
        isCurrentSubject: @escaping (SubjectStamp) -> Bool
    ) {
        self.fetchStatus = fetchStatus
        self.recordCompleted = recordCompleted
        self.subjectStamp = subjectStamp
        self.isCurrentSubject = isCurrentSubject
    }

    /// サーバーから完了の状態を取得する。値が無ければ（API 未設定）何も書かない。
    /// 取得に失敗したら完了として扱い、行き止まりを作らない。前の主体の遅延応答は捨てる。
    func refresh() async {
        let stamp = subjectStamp()
        do {
            guard let status = try await fetchStatus() else { return }
            guard isCurrentSubject(stamp) else { return }
            isCompleted = status
        } catch {
            guard isCurrentSubject(stamp) else { return }
            isCompleted = true
        }
    }

    /// 完了を記録する。記録に失敗しても完了として扱い、次回起動で再取得される。
    func complete() async {
        let stamp = subjectStamp()
        _ = try? await recordCompleted()
        guard isCurrentSubject(stamp) else { return }
        isCompleted = true
    }
}
