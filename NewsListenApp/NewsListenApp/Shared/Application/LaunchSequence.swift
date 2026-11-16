//
//  LaunchSequence.swift
//  NewsListenApp
//
//  主体の確定後に context をまたぐ起動時の手順を順に起こす。順序は「設定の同期の完了 → 通知の登録」で、
//  同期の途中で主体が変わったら登録しない。入口は closure で受けるので adapter なしで動く。
//

import Foundation

@MainActor
final class LaunchSequence {
    private let refreshPreferences: () async -> Void
    private let registerPush: () async -> Void
    private let subjectStamp: () -> SubjectStamp
    private let isCurrentSubject: (SubjectStamp) -> Bool

    init(
        refreshPreferences: @escaping () async -> Void,
        registerPush: @escaping () async -> Void,
        subjectStamp: @escaping () -> SubjectStamp,
        isCurrentSubject: @escaping (SubjectStamp) -> Bool
    ) {
        self.refreshPreferences = refreshPreferences
        self.registerPush = registerPush
        self.subjectStamp = subjectStamp
        self.isCurrentSubject = isCurrentSubject
    }

    func run() async {
        let stamp = subjectStamp()
        guard isCurrentSubject(stamp) else { return }
        await refreshPreferences()
        guard isCurrentSubject(stamp) else { return }
        await registerPush()
    }
}
