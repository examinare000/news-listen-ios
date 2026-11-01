//
//  PreferencesStore.swift
//  NewsListenApp
//
//  設定の現在値の持ち主（application）。サーバーとの同期・失敗時の巻き戻し・前の主体の遅延応答の破棄・
//  主体依存の消去をここが持つ（ios-cmd-prefs-01〜ios-cmd-prefs-04・ios-rule-prefs-04〜ios-rule-prefs-06）。
//  通信と保存は下の port（gateway・storage）の向こうにあり、この層は UserDefaults も APIClient も知らない。
//

import Foundation
import Combine

// MARK: - port

struct PreferencesGateway {
    let fetch: () async throws -> PreferenceValues
    let update: (PreferenceChange) async throws -> Void
}

/// サーバーから取得した値。値域の外は変換で捨てて nil にする。
struct PreferenceValues: Equatable {
    let difficulty: DifficultyLevel?
    let playbackSpeed: Double?
    let weeklyGoal: WeeklyGoalTarget?
}

enum PreferenceChange: Equatable { case difficulty(DifficultyLevel), playbackSpeed(Double), weeklyGoal(WeeklyGoalTarget) }

/// 端末に保存された 7 つの値（値域の外・未保存は既定に倒して読む）。
struct PreferenceSnapshot: Equatable {
    let difficulty: DifficultyLevel
    let playbackSpeed: Double
    let weeklyGoal: WeeklyGoalTarget
    let articleOpenMode: ArticleOpenMode
    let timeFormat: TimeFormat
    let soundEnabled: Bool
    let hapticsEnabled: Bool
}

enum StoredPreference: Equatable { case difficulty(DifficultyLevel), playbackSpeed(Double), weeklyGoal(WeeklyGoalTarget), articleOpenMode(ArticleOpenMode), timeFormat(TimeFormat), soundEnabled(Bool), hapticsEnabled(Bool) }

struct PreferenceStorage {
    let read: () -> PreferenceSnapshot
    let write: (StoredPreference) -> Void
    let clearSubjectScoped: () -> Void
}

// MARK: - store

@MainActor final class PreferencesStore: ObservableObject {
    @Published private(set) var defaultDifficulty: DifficultyLevel
    @Published private(set) var defaultPlaybackSpeed: Double
    @Published private(set) var weeklyGoal: WeeklyGoalTarget
    @Published private(set) var articleOpenMode: ArticleOpenMode
    @Published private(set) var timeFormat: TimeFormat
    @Published private(set) var soundEnabled: Bool
    @Published private(set) var hapticsEnabled: Bool
    @Published private(set) var syncFailed: Bool

    private let gateway: PreferencesGateway?
    private let storage: PreferenceStorage
    private let isCurrentSubject: (SubjectStamp) -> Bool
    private let subjectStamp: () -> SubjectStamp
    private let isAuthenticated: () -> Bool

    /// サーバーが最後に成功を返した週の目標。成功のときだけ書く（失敗した値は確認済みにしない）。
    private var lastConfirmed: WeeklyGoalTarget
    /// 項目ごとの要求番号。最新の要求の失敗だけが巻き戻す。
    private var latestDifficultyRequestId = 0
    private var latestSpeedRequestId = 0
    private var latestWeeklyGoalRequestId = 0

    init(gateway: PreferencesGateway?, storage: PreferenceStorage, isCurrentSubject: @escaping (SubjectStamp) -> Bool, subjectStamp: @escaping () -> SubjectStamp, isAuthenticated: @escaping () -> Bool) {
        self.gateway = gateway
        self.storage = storage
        self.isCurrentSubject = isCurrentSubject
        self.subjectStamp = subjectStamp
        self.isAuthenticated = isAuthenticated
        let snapshot = storage.read()
        defaultDifficulty = snapshot.difficulty
        defaultPlaybackSpeed = snapshot.playbackSpeed
        weeklyGoal = snapshot.weeklyGoal
        articleOpenMode = snapshot.articleOpenMode
        timeFormat = snapshot.timeFormat
        soundEnabled = snapshot.soundEnabled
        hapticsEnabled = snapshot.hapticsEnabled
        syncFailed = false
        lastConfirmed = snapshot.weeklyGoal
    }

    // MARK: サーバー同期の command（失敗は同じ error を投げ直す。巻き戻しは 1 行）

    func setDefaultDifficulty(_ v: DifficultyLevel) async throws {
        guard isAuthenticated() else {
            defaultDifficulty = .default
            return
        }
        let oldValue = defaultDifficulty
        defaultDifficulty = v
        storage.write(.difficulty(v))
        let stamp = subjectStamp()
        latestDifficultyRequestId += 1
        let requestId = latestDifficultyRequestId
        do {
            try await gateway?.update(.difficulty(v))
        } catch {
            if requestId == latestDifficultyRequestId, isCurrentSubject(stamp) { defaultDifficulty = oldValue; storage.write(.difficulty(oldValue)) }
            throw error
        }
    }

    func setDefaultPlaybackSpeed(_ v: Double) async throws {
        guard isAuthenticated() else {
            defaultPlaybackSpeed = PreferenceCatalog.defaultPlaybackSpeed
            return
        }
        guard PlaybackConstants.speeds.contains(Float(v)) else { return }
        let oldValue = defaultPlaybackSpeed
        defaultPlaybackSpeed = v
        storage.write(.playbackSpeed(v))
        let stamp = subjectStamp()
        latestSpeedRequestId += 1
        let requestId = latestSpeedRequestId
        do {
            try await gateway?.update(.playbackSpeed(v))
        } catch {
            if requestId == latestSpeedRequestId, isCurrentSubject(stamp) { defaultPlaybackSpeed = oldValue; storage.write(.playbackSpeed(oldValue)) }
            throw error
        }
    }

    func setWeeklyGoal(_ v: WeeklyGoalTarget) async throws {
        guard isAuthenticated() else {
            weeklyGoal = .default
            return
        }
        let oldValue = weeklyGoal
        weeklyGoal = v
        storage.write(.weeklyGoal(v))
        guard lastConfirmed != v else { return }
        let stamp = subjectStamp()
        latestWeeklyGoalRequestId += 1
        let requestId = latestWeeklyGoalRequestId
        do {
            try await gateway?.update(.weeklyGoal(v))
            if isCurrentSubject(stamp) { lastConfirmed = v }
        } catch {
            if requestId == latestWeeklyGoalRequestId, isCurrentSubject(stamp) { weeklyGoal = oldValue; storage.write(.weeklyGoal(oldValue)) }
            throw error
        }
    }

    // MARK: 端末設定の command

    func setArticleOpenMode(_ v: ArticleOpenMode) {
        articleOpenMode = v
        storage.write(.articleOpenMode(v))
    }

    func setTimeFormat(_ v: TimeFormat) {
        timeFormat = v
        storage.write(.timeFormat(v))
    }

    func setSoundEnabled(_ v: Bool) {
        soundEnabled = v
        storage.write(.soundEnabled(v))
    }

    func setHapticsEnabled(_ v: Bool) {
        hapticsEnabled = v
        storage.write(.hapticsEnabled(v))
    }

    // MARK: 主体離脱・取得

    /// 主体依存の 3 値と確認済みの週の目標を既定へ戻し、保存から主体依存の項目を消す。`syncFailed` は触らない。
    func clearSubjectScoped() {
        defaultDifficulty = .default
        defaultPlaybackSpeed = PreferenceCatalog.defaultPlaybackSpeed
        weeklyGoal = .default
        lastConfirmed = .default
        storage.clearSubjectScoped()
    }

    /// サーバーの値を端末の保存へ取り込む。サーバーへは書かない。値域の内の値だけを反映する。
    func refreshFromServer() async {
        guard isAuthenticated(), let gateway else { return }
        let stamp = subjectStamp()
        do {
            let values = try await gateway.fetch()
            guard isCurrentSubject(stamp) else { return }
            if let difficulty = values.difficulty {
                storage.write(.difficulty(difficulty))
                defaultDifficulty = difficulty
            }
            if let speed = values.playbackSpeed {
                storage.write(.playbackSpeed(speed))
                defaultPlaybackSpeed = speed
            }
            if let goal = values.weeklyGoal {
                storage.write(.weeklyGoal(goal))
                weeklyGoal = goal
                lastConfirmed = goal
            }
            syncFailed = false
        } catch is ApiFailure {
            guard isCurrentSubject(stamp) else { return }
            syncFailed = true
        } catch {
            // ApiFailure 以外（キャンセル）は失敗として扱わない。
        }
    }
}
