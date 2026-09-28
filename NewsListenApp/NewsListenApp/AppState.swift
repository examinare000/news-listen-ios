//
//  AppState.swift
//  NewsListenApp
//
//  アプリ全体で共有するユーザー設定（API URL・キー・難易度・再生速度）と認証状態を保持する。
//  設定値は `PreferenceRegistry` 経由で永続化し、認証状態は `AuthSession`（I-S2）で表す。
//  SwiftUI から @StateObject / @EnvironmentObject で参照する。
//

import Foundation
import Combine

/// 記事タップ時の遷移先。アプリ内 Safari（既定）か外部 Safari かを選べる（要件 §3.2/§3.6・AC-5）。
enum ArticleOpenMode: String, CaseIterable, Identifiable {
    /// アプリ内 Safari（`SFSafariViewController`）で開く。
    case inApp = "in_app"
    /// 外部 Safari アプリで開く。
    case external = "external"

    /// `ForEach` 等で利用する一意な識別子（rawValue を流用）。
    var id: String { rawValue }

    /// 設定画面の Picker に表示する日本語ラベル。
    var label: String {
        switch self {
        case .inApp: return "アプリ内 Safari"
        case .external: return "外部 Safari"
        }
    }
}

/// 認証状態（I-S2 / spec §3.1）。判別共用体で 4 状態のみを表す。
enum AuthSession: Equatable {
    /// 保存済みトークンで `/auth/me` を解決中（初期値）。
    case resolving
    /// ログイン済み。
    case authenticated(AuthUser)
    /// 未ログイン（トークン無し、または `fetchMe` が `unauthorized`）。
    case anonymous
    /// `/auth/me` が `unauthorized` 以外の理由で失敗（トークンは保持）。
    case unavailable(ApiFailure)
}

/// 主体の照合値（I-S2）。`AppState` の外で await をまたいで状態を書く呼出元が、await の前に
/// 捕捉し、await の後に `isCurrentSubject(_:)` で照合してから書き込む。
///
/// 保存トークンを内部に持つが、`AppState.swift` の外からは読めない（`token` は `fileprivate`）。
/// stamp から client を作る・トークンを取り出す経路は作らない（token provider 注入との違い: spec §4）。
struct SubjectStamp {
    fileprivate let token: String?
}

/// アプリ全体で共有するユーザー設定・認証状態を保持する状態オブジェクト。
///
/// - Note: `apiClient` で `@MainActor` 分離の ``APIClient`` を生成するため、`AppState` 自体も
///   `@MainActor` にする。UI 状態であり常にメインスレッドで更新されるため分離方針とも整合する。
@MainActor
final class AppState: ObservableObject {
    /// API のベース URL。ビルド時に `Secrets.xcconfig` → Info.plist 経由で注入する（ADR-037）。
    /// ユーザー入力・UserDefaults 保存は廃止し、実行時は不変。
    let apiBaseURL: String

    /// API キー（共有ゲートウェイキー）。ビルド時に `Secrets.xcconfig` → Info.plist 経由で
    /// 注入する（ADR-037）。ユーザー入力・UserDefaults 保存は廃止し、実行時は不変。
    let apiKey: String

    /// 認証状態。`session` が唯一の正本（I-S2）。
    @Published private(set) var session: AuthSession = .resolving

    /// ログイン中ユーザー。`session` からの導出値（stored ではない: 同じ事実を二重に持たない）。
    var currentUser: AuthUser? {
        if case .authenticated(let user) = session { return user }
        return nil
    }

    /// その時点の保存トークンで作る主体の照合値。
    var subjectStamp: SubjectStamp { SubjectStamp(token: sessionStore.token) }

    /// `stamp` が現在の主体と一致するか（authenticated ∧ 保存トークン != nil ∧ 捕捉時と同じ）。
    func isCurrentSubject(_ stamp: SubjectStamp) -> Bool {
        guard case .authenticated = session, let token = stamp.token, sessionStore.token == token else {
            return false
        }
        return true
    }

    /// Podcast 生成時の既定難易度。変更時に registry へ保存する（authenticated の間のみ永続化: CI-T15.8）。
    @Published var defaultDifficulty: String {
        didSet { persistSubjectScopedOrReset(\.defaultDifficulty, current: defaultDifficulty) { defaultDifficulty = $0 } }
    }

    /// 既定の再生速度。変更時に registry へ保存する（authenticated の間のみ永続化: CI-T15.8）。
    @Published var defaultPlaybackSpeed: Double {
        didSet { persistSubjectScopedOrReset(\.defaultPlaybackSpeed, current: defaultPlaybackSpeed) { defaultPlaybackSpeed = $0 } }
    }

    /// 1 週間に完聴する目標本数。設定可能値は 3 / 5 / 7 / 10。
    @Published var weeklyGoalEpisodes: Int {
        didSet { persistSubjectScopedOrReset(\.weeklyGoalEpisodes, current: weeklyGoalEpisodes) { weeklyGoalEpisodes = $0 } }
    }

    /// サーバーで最後に同期確認された週次目標。ローカルの新値とこれが異なる場合だけ同期を試みる。
    /// レース対策: UI の revert 代入が onChange を再発火してループする問題を防ぐため、
    /// 確認済み値と比較して不要な同期を省略する（issue #164）。主体には属すがメモリのみ（registry 外）。
    @Published private(set) var lastConfirmedWeeklyGoalEpisodes: Int = 3

    /// 記事タップ時の開き方。端末ローカル設定のため authenticated 状態に関わらず常に永続化する。
    @Published var articleOpenMode: ArticleOpenMode {
        didSet {
            guard didFinishInit else { return }
            preferences.set(preferences.articleOpenMode, articleOpenMode.rawValue)
        }
    }

    /// 記事の日付表記方式（"absolute" | "relative"）。端末ローカル設定のため常に永続化する。
    @Published var timeFormat: String {
        didSet {
            guard didFinishInit else { return }
            preferences.set(preferences.timeFormat, timeFormat)
        }
    }

    /// 初回オンボーディング（おすすめ追加ステップ）の完了状態。
    ///
    /// サーバ側（`UserPrefs.onboarding_completed`）が正であり、起動ごとに取得する。
    /// `nil`=未取得（判定保留）。`false` のときのみ追加ステップを提示する。
    /// launch 時のブロッキングを避けるため、ルーティングは `ContentView` 上の fullScreenCover で行う。
    @Published var onboardingCompleted: Bool?

    /// 直近の `refreshPreferences()` が失敗したか（issue #164・サイレント失敗解消）。
    ///
    /// 失敗してもローカルの `defaultDifficulty`/`defaultPlaybackSpeed` は保持する既存仕様は
    /// 変えず、失敗の有無だけを可視化して設定画面のインライン警告・再試行導線に使う。
    @Published var preferencesSyncFailed = false

    /// アプリ全体で共有する聴取ストリーク。未取得・未提供時は `nil`。
    @Published var listeningStreak: ListeningStreak?

    /// 直近のストリーク取得が 404 以外で失敗したか。
    @Published var listeningStreakLoadFailed = false

    /// プッシュ通知タップで開く対象 Podcast ID（ディープリンク・issue #80）。
    /// 設定されると Podcast タブへ遷移して再生する。遷移後は受け手が nil に戻す。
    @Published var selectedPodcastId: String?

    /// 直近の主体離脱の後始末が一部失敗したか（I-S2 / CI-T15.3）。全成功なら `nil`。
    @Published private(set) var lastCleanupIncomplete: CleanupIncomplete?

    /// 取得済みの APNs デバイストークン（16 進）。未取得なら `nil`。
    /// 資格情報ではないがログには出さない。認証確立後に backend へ登録する。
    private(set) var apnsDeviceToken: String?

    /// セッショントークンの保管先（既定は Keychain、テストはインメモリ）。
    private let sessionStore: SessionStore

    /// 設定宣言の正本（I-S2）。
    private let preferences: PreferenceRegistry

    /// ロック画面/コントロールセンターの表示クリア port（主体離脱の後始末で使う）。
    private let nowPlayingCenter: NowPlayingCenter

    /// 再生停止 port。`ContentView` が `registerPlaybackLifecycle(_:)` で登録する（weak）。
    private weak var playbackLifecycle: PlaybackLifecycle?

    /// 音声キャッシュ削除（主体離脱の後始末）。本番は `AudioCacheManager.clearCache()`。
    private let clearOfflineLibrary: () throws -> Void

    /// デバイストークン登録の投げっぱなし Task。`logout()` との競合を避けるため、
    /// 起動時に既存タスクを cancel してから差し替える。
    private var deviceTokenRegistrationTask: Task<Void, Never>?

    /// `refreshAuth()` が起動時の preferences 同期に使う非構造化 Task（D-10）。
    /// 呼び出し元（`ProgressView.task`）のキャンセルがこの同期に伝わらないようにする。
    private var preferencesSyncTask: Task<Void, Never>?

    /// テスト時に ``APIClient`` を直接注入するための上書き（既定 `nil`、最優先）。
    private let apiClientOverride: APIClient?

    /// テスト seam（D-3）: 保存トークンと unauthorized observer から ``APIClient`` を作る factory。
    /// `apiClientOverride` の次に優先する。既定 `nil`（本番は下の computed 生成）。
    private let apiClientFactory: ((String?, @escaping @MainActor () -> Void) -> APIClient)?

    /// init 完了後かどうか。init 内の初期代入では didSet の永続化処理を走らせない。
    private var didFinishInit = false
    /// 主体依存設定を既定値へ戻す代入の再帰防止フラグ（didSet からの自己代入用）。
    private var isResettingSubjectScopedPreferences = false

    /// 現在の設定から生成した ``APIClient``。優先順位: override > factory > 本番生成（D-3）。
    ///
    /// 生成時に読んだ保存トークンを unauthorized observer に捕捉させる（CI-T14.15）。
    /// これにより、そのクライアントが送るリクエストの 401 は「そのリクエストに使ったトークン」
    /// と照合してから遷移できる（前の主体の遅延応答が次の主体を巻き込まない）。
    var apiClient: APIClient? {
        if let apiClientOverride { return apiClientOverride }
        let token = sessionStore.token
        if let apiClientFactory {
            return apiClientFactory(token) { [weak self] in
                self?.handle(failure: .unauthorized, sentToken: token)
            }
        }
        guard !apiBaseURL.isEmpty, !apiKey.isEmpty,
              let url = URL(string: apiBaseURL) else { return nil }
        return APIClient(
            baseURL: url,
            apiKey: apiKey,
            sessionToken: token,
            onUnauthorized: { [weak self] in
                self?.handle(failure: .unauthorized, sentToken: token)
            }
        )
    }

    /// API URL とキーがともに設定済みかどうか。初期設定画面の出し分けに使う。
    var isConfigured: Bool { !apiBaseURL.isEmpty && !apiKey.isEmpty }

    // MARK: - 認証

    /// ログイン成功を受けてトークンを Keychain に保存し、ユーザー状態を更新する。
    /// - Parameter response: ログイン API のレスポンス。
    func completeLogin(_ response: LoginResponse) {
        sessionStore.token = response.token
        session = .authenticated(response.user)
        // ログイン直後、取得済みトークンがあれば backend に登録する。
        scheduleDeviceTokenRegistration()
    }

    /// `AccountSettingsView.saveProfile()` 等、AppState の外で await した後にプロフィールを
    /// 差し替える呼出元向けの API（I-S2 / G9）。`capturedAt` は await の前に捕捉した stamp。
    /// - Parameters:
    ///   - user: 差し替え後のユーザー情報。
    ///   - stamp: await の前に捕捉した `subjectStamp`。
    func updateCurrentUser(_ user: AuthUser, capturedAt stamp: SubjectStamp) {
        guard isCurrentSubject(stamp) else { return }
        session = .authenticated(user)
    }

    /// `unavailable` から再解決を試みる（`retryResolve()`）。`unavailable` 以外からは no-op。
    func retryResolve() {
        guard case .unavailable = session else { return }
        session = .resolving
    }

    /// Authorization 付きリクエストが 401 を返したときに `APIClient` の observer から呼ばれる
    /// （CI-T14.7・CI-T14.8）。authenticated ∧ `sentToken` が保存トークンと一致するときだけ、
    /// 主体離脱の後始末を実行する。それ以外は状態・token・後始末とも変えない。
    /// - Parameters:
    ///   - failure: 観測した失敗。
    ///   - sentToken: そのリクエストに使ったトークン（client 生成時点の保存トークン）。
    func handle(failure: ApiFailure, sentToken: String?) {
        guard case .authenticated = session,
              failure == .unauthorized,
              let sentToken, sentToken == sessionStore.token else { return }
        performLeaveProcessing()
    }

    // MARK: - Push（APNs デバイストークン）

    /// AppDelegate から APNs デバイストークンを受け取り、可能なら backend へ登録する。
    /// - Parameter token: 16 進のデバイストークン。
    func didRegisterDeviceToken(_ token: String) {
        apnsDeviceToken = token
        scheduleDeviceTokenRegistration()
    }

    /// デバイストークン登録を投げっぱなし Task としてスケジュールする。
    ///
    /// 既存の登録タスクがあれば先に cancel してから差し替えることで、`logout()` の
    /// cancel 呼び出しが常に「最新の登録試行」を確実に止められるようにする
    /// （issue #80 レビュー指摘：`refreshAuth()` 経由の登録も追跡対象に含める）。
    private func scheduleDeviceTokenRegistration() {
        deviceTokenRegistrationTask?.cancel()
        deviceTokenRegistrationTask = Task { await registerDeviceTokenIfPossible() }
    }

    /// 認証済みかつトークン取得済みのとき、デバイストークンを backend へ登録する（ベストエフォート）。
    ///
    /// `logout()` は先に `deviceTokenRegistrationTask.cancel()` を呼ぶため、この
    /// `!Task.isCancelled` チェックが register 発火とログアウトの競合を締める。
    func registerDeviceTokenIfPossible() async {
        guard case .authenticated = session,
              let apiClient, let token = apnsDeviceToken,
              !Task.isCancelled else { return }
        _ = try? await apiClient.registerDeviceToken(token)
    }

    /// プッシュ通知タップで対象 Podcast へ遷移する（ディープリンク）。
    /// - Parameter podcastId: 遷移先の Podcast ID。
    func handleNotificationPodcastId(_ podcastId: String) {
        selectedPodcastId = podcastId
    }

    /// 保存済みトークンで `/auth/me` を解決し、認証状態を確定する（G1・G2）。
    /// 認証成功後、サーバーから preferences を取得してローカル設定を同期する。
    ///
    /// 未設定・トークン無しは anonymous。開始時に捕捉した `t0` と、await の後の
    /// `session == .resolving ∧ 保存トークン == t0` の両方を満たすときだけ結果を書く
    /// （前の主体の遅延応答が後発の主体を書き換えない: G-S2-12）。
    func refreshAuth() async {
        guard case .resolving = session else { return }
        let t0 = sessionStore.token
        guard let t0, let apiClient else {
            session = .anonymous
            return
        }
        do {
            let user = try await apiClient.fetchMe()
            guard case .resolving = session, sessionStore.token == t0 else { return }
            session = .authenticated(user)
            // 起動時の preferences 同期は AppState 保持の非構造化 Task で行う。呼び出し元
            // （`ProgressView.task`）がキャンセルされても、この同期は中断されない（D-10）。
            let syncTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.refreshPreferences()
            }
            preferencesSyncTask = syncTask
            await syncTask.value
            // G2（改訂 4・SR-12）: 同期完了待ちの後、まだ自分の主体のときだけ登録を予約する。
            guard case .authenticated = session, sessionStore.token == t0 else { return }
            scheduleDeviceTokenRegistration()
        } catch ApiFailure.unauthorized {
            guard case .resolving = session, sessionStore.token == t0 else { return }
            sessionStore.token = nil
            session = .anonymous
        } catch let failure as ApiFailure {
            guard case .resolving = session, sessionStore.token == t0 else { return }
            session = .unavailable(failure)
        } catch {
            // ApiFailure 以外（キャンセル）は制御信号のため、状態・token とも変えない（A11）。
        }
    }

    /// サーバーから preferences を取得し、ローカルの主体依存設定を更新する（G3）。
    /// 呼出時点で authenticated かつ保存トークンが無ければ no-op。取得失敗時は既存値を保持
    /// しつつ `preferencesSyncFailed` を立てる（issue #164）。キャンセルは失敗として扱わない。
    func refreshPreferences() async {
        guard case .authenticated = session, let t0 = sessionStore.token, let apiClient else { return }
        do {
            let serverPreferences = try await apiClient.fetchPreferences()
            guard case .authenticated = session, sessionStore.token == t0 else { return }
            if let difficulty = serverPreferences.defaultDifficulty,
               preferences.set(preferences.defaultDifficulty, difficulty) {
                defaultDifficulty = difficulty
            }
            if let speed = serverPreferences.defaultPlaybackSpeed,
               preferences.set(preferences.defaultPlaybackSpeed, speed) {
                defaultPlaybackSpeed = speed
            }
            if let weeklyGoal = serverPreferences.weeklyGoalEpisodes,
               preferences.set(preferences.weeklyGoalEpisodes, weeklyGoal) {
                weeklyGoalEpisodes = weeklyGoal
                // サーバーから正常に同期できたので、確認済み値を更新する
                lastConfirmedWeeklyGoalEpisodes = weeklyGoal
            }
            preferencesSyncFailed = false
        } catch is ApiFailure {
            guard case .authenticated = session, sessionStore.token == t0 else { return }
            preferencesSyncFailed = true
        } catch {
            // ApiFailure 以外（キャンセル）は失敗として扱わない（CI-T15.10・S1 D2）。
        }
    }

    /// サーバーから聴取ストリークを取得して共有状態を更新する（G5）。
    ///
    /// 404 は旧 backend または未提供機能として非表示へ graceful degradation する。
    /// 旧値→新値で currentStreakDays が増加していれば streakUp フィードバックを発火。
    /// 開始時に捕捉した保存トークンと await の後で一致するときだけ結果を書く。
    func refreshListeningStreak() async {
        let t0 = sessionStore.token
        guard let apiClient else { return }
        let previousStreakDays = listeningStreak?.currentStreakDays
        do {
            let newStreak = try await apiClient.fetchListeningStreak()
            guard sessionStore.token == t0 else { return }
            listeningStreak = newStreak
            listeningStreakLoadFailed = false
            // 初回ロード（previousStreakDays == nil）では発火させない。
            // 既存値から増加した場合のみ streakUp フィードバック。
            if let prev = previousStreakDays, newStreak.currentStreakDays > prev {
                DSFeedback.shared.play(.streakUp)
            }
        } catch ApiFailure.notFound(subject: .streak) {
            guard sessionStore.token == t0 else { return }
            listeningStreak = nil
            listeningStreakLoadFailed = false
        } catch {
            guard sessionStore.token == t0 else { return }
            listeningStreak = nil
            listeningStreakLoadFailed = true
        }
    }

    /// 週次目標の同期確認を記録する（G10）。`capturedAt` は await の前に捕捉した stamp。
    /// - Parameters:
    ///   - value: サーバーで確認された週次目標。
    ///   - stamp: await の前に捕捉した `subjectStamp`。
    func confirmWeeklyGoalSync(_ value: Int, capturedAt stamp: SubjectStamp) {
        guard isCurrentSubject(stamp) else { return }
        lastConfirmedWeeklyGoalEpisodes = value
    }

    /// ログアウトしてサーバ側セッションを破棄し、ローカル状態を未認証にする（G4）。
    ///
    /// 開始時に `t0` を捕捉し、サーバ呼出（ベストエフォート）を await した後、保存トークンが
    /// `t0` のままのときだけ遷移する。別の主体のトークン・状態・後始末には触れない（CI-T14.12）。
    func logout() async {
        let t0 = sessionStore.token
        // 進行中のデバイストークン登録タスクをキャンセルし、logout 後にサーバへ登録リクエストが
        // 到達してトークン紐付けが復活する競合を防ぐ（issue #80 レビュー指摘）。
        deviceTokenRegistrationTask?.cancel()
        if let apiClient {
            // 他ユーザーへの誤配信を避けるため、ログアウト前にデバイストークンの解除を試みる
            // （ベストエフォート。失敗するとサーバ側の紐付けは残存し、同一端末で次のユーザーが
            // 登録し直す（同一トークンの upsert 上書き）まで旧ユーザー宛通知が届き得る。
            // 少数ユーザー運用の現段階ではこのリスクを許容し、失敗時リトライは導入しない）。
            if let token = apnsDeviceToken {
                _ = try? await apiClient.unregisterDeviceToken(token)
            }
            _ = try? await apiClient.logout()
        }
        guard sessionStore.token == t0 else { return }
        if case .authenticated = session {
            performLeaveProcessing()
        } else {
            sessionStore.token = nil
            session = .anonymous
        }
    }

    /// 主体離脱（logout・失効の両方）の事後条件を実行する（spec §3.2）。呼出元は、呼ぶ直前に
    /// `session` が authenticated かつ保存トークンが自分の照合値と一致することを確かめておくこと。
    private func performLeaveProcessing() {
        sessionStore.token = nil
        session = .anonymous
        let cleanup = SubjectCleanup(
            playbackLifecycle: playbackLifecycle,
            nowPlayingCenter: nowPlayingCenter,
            clearSubjectPreferences: { [weak self] in self?.resetSubjectScopedPreferencesToDefaults() },
            clearOfflineLibrary: clearOfflineLibrary
        )
        lastCleanupIncomplete = cleanup.run()
    }

    /// AppState が保持する主体依存値をメモリ上で registry 既定値へ戻し、registry の
    /// subjectScoped key を UserDefaults から削除する（spec §3.2 手順 3）。
    private func resetSubjectScopedPreferencesToDefaults() {
        defaultDifficulty = preferences.defaultDifficulty.defaultValue
        defaultPlaybackSpeed = preferences.defaultPlaybackSpeed.defaultValue
        weeklyGoalEpisodes = preferences.weeklyGoalEpisodes.defaultValue
        lastConfirmedWeeklyGoalEpisodes = preferences.weeklyGoalEpisodes.defaultValue
        preferences.clearSubjectScoped()
    }

    /// 主体依存 3 プロパティ（`defaultDifficulty`・`defaultPlaybackSpeed`・`weeklyGoalEpisodes`）の
    /// 共通 didSet ロジック（CI-T15.8）。authenticated の間だけ registry へ永続化し、それ以外は
    /// 代入を registry 既定値へ戻す（再帰は `isResettingSubjectScopedPreferences` で 1 段だけ抑止）。
    private func persistSubjectScopedOrReset<Value>(
        _ setting: KeyPath<PreferenceRegistry, PreferenceSetting<Value>>,
        current: Value,
        reset: (Value) -> Void
    ) {
        guard didFinishInit, !isResettingSubjectScopedPreferences else { return }
        guard case .authenticated = session else {
            isResettingSubjectScopedPreferences = true
            reset(preferences[keyPath: setting].defaultValue)
            isResettingSubjectScopedPreferences = false
            return
        }
        preferences.set(preferences[keyPath: setting], current)
    }

    /// 登録済みの `PlaybackLifecycle` を差し替える（weak）。`ContentView` が表示時に呼ぶ（CI-T15.9）。
    /// - Parameter lifecycle: 再生停止の実処理を持つオブジェクト。
    func registerPlaybackLifecycle(_ lifecycle: PlaybackLifecycle) {
        playbackLifecycle = lifecycle
    }

    /// サーバから初回オンボーディング状態を取得し `onboardingCompleted` を更新する（G6）。
    ///
    /// 取得失敗時は `true` 扱いとし、追加ステップを挟まずフィードへ進ませる（行き止まりを防ぐ）。
    func refreshOnboardingStatus() async {
        let t0 = sessionStore.token
        guard let apiClient else { return }
        do {
            let status = try await apiClient.fetchOnboardingStatus()
            guard sessionStore.token == t0 else { return }
            onboardingCompleted = status.onboardingCompleted
        } catch {
            guard sessionStore.token == t0 else { return }
            onboardingCompleted = true
        }
    }

    /// 初回オンボーディング完了をサーバに記録し、ローカル状態も完了にする（G7）。
    ///
    /// 保存に失敗しても UI 上は完了として扱い、追加ステップを閉じる（次回起動時に再取得される）。
    func completeOnboarding() async {
        let t0 = sessionStore.token
        guard let apiClient else {
            onboardingCompleted = true
            return
        }
        _ = try? await apiClient.completeOnboarding()
        guard sessionStore.token == t0 else { return }
        onboardingCompleted = true
    }

    /// ビルド時に Secrets.xcconfig → Info.plist 経由で注入された既定値を読む。
    ///
    /// 未注入（空文字や未置換のまま）の場合は `nil` を返す。
    /// - Parameter key: Info.plist のキー名。
    private static func injectedValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // xcconfig 未設定時は "$(API_KEY)" のような未置換文字列が残るため弾く。
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// 永続化済みの設定を読み込んで状態を初期化する。
    ///
    /// API URL・キーはビルド注入値(Info.plist←Secrets.xcconfig)のみを読む（ADR-037、#25）。
    /// その他の値は `PreferenceRegistry` 経由で読む（「ユーザーが保存した値 > 既定値」の優先順位）。
    /// - Parameters:
    ///   - sessionStore: セッショントークンの保管先。既定は Keychain。テストで差し替える。
    ///   - apiClientOverride: テスト時に注入する ``APIClient``（既定 `nil`、最優先）。
    ///   - apiClientFactory: テスト seam（D-3）。保存トークンと observer から client を作る factory。
    ///   - preferences: 設定宣言の正本。既定は `.standard` を使う `PreferenceRegistry()`。
    ///   - nowPlayingCenter: ロック画面表示クリア port。既定は本番実装。
    ///   - clearOfflineLibrary: 音声キャッシュ削除。既定は `AudioCacheManager().clearCache()`。
    init(
        sessionStore: SessionStore = KeychainSessionStore(),
        apiClientOverride: APIClient? = nil,
        apiClientFactory: ((String?, @escaping @MainActor () -> Void) -> APIClient)? = nil,
        preferences: PreferenceRegistry = PreferenceRegistry(),
        nowPlayingCenter: NowPlayingCenter = MediaPlayerNowPlaying(),
        clearOfflineLibrary: @escaping () throws -> Void = { try AudioCacheManager().clearCache() }
    ) {
        self.sessionStore = sessionStore
        self.apiClientOverride = apiClientOverride
        self.apiClientFactory = apiClientFactory
        self.preferences = preferences
        self.nowPlayingCenter = nowPlayingCenter
        self.clearOfflineLibrary = clearOfflineLibrary
        // API URL・キーはビルド時注入のみ（ユーザー入力・UserDefaults フォールバックは廃止）。
        self.apiBaseURL = Self.injectedValue("APIBaseURL") ?? ""
        self.apiKey = Self.injectedValue("APIKey") ?? ""
        self.defaultDifficulty = preferences.get(preferences.defaultDifficulty)
        self.defaultPlaybackSpeed = preferences.get(preferences.defaultPlaybackSpeed)
        let resolvedWeeklyGoal = preferences.get(preferences.weeklyGoalEpisodes)
        self.weeklyGoalEpisodes = resolvedWeeklyGoal
        self.lastConfirmedWeeklyGoalEpisodes = resolvedWeeklyGoal
        self.articleOpenMode = ArticleOpenMode(rawValue: preferences.get(preferences.articleOpenMode)) ?? .inApp
        self.timeFormat = preferences.get(preferences.timeFormat)
        didFinishInit = true
    }
}
