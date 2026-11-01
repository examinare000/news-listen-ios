//
//  AppState.swift
//  NewsListenApp
//
//  アプリ全体で共有する API URL・キーと認証状態を保持する。
//  認証状態は `AuthSession`（ios-slice-auth-01）で表す。ユーザー設定の現在値は `PreferencesStore` が持つ。
//  SwiftUI から @StateObject / @EnvironmentObject で参照する。
//

import Foundation
import Combine

/// ログイン成功の結果（ios-cmd-account-01 の receipt）。ログイン VM が応答から作り、`completeLogin` へ渡す。
struct LoginReceipt: Equatable {
    let token: String
    let subject: Subject
}

/// 主体の照合値（ios-slice-auth-01）。`AppState` の外で await をまたいで状態を書く呼出元が、await の前に
/// 捕捉し、await の後に `isCurrentSubject(_:)` で照合してから書き込む。
///
/// 保存トークンを内部に持つが、`AppState.swift` の外からは読めない（`token` は `fileprivate`）。
/// stamp から client を作る・トークンを取り出す経路は作らない（token provider 注入との違い: spec §4）。
struct SubjectStamp {
    fileprivate let token: String?
}

/// アプリ全体で共有する認証状態を保持する状態オブジェクト（ユーザー設定は `PreferencesStore` が持つ）。
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

    /// 認証状態。`session` が唯一の正本（ios-slice-auth-01）。
    @Published private(set) var session: AuthSession = .resolving

    /// ログイン中ユーザー。`session` からの導出値（stored ではない: 同じ事実を二重に持たない）。
    var currentSubject: Subject? {
        if case .authenticated(let subject) = session { return subject }
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

    /// 初回オンボーディング（おすすめ追加ステップ）の完了状態。
    ///
    /// サーバ側（`UserPrefs.onboarding_completed`）が正であり、起動ごとに取得する。
    /// `nil`=未取得（判定保留）。`false` のときのみ追加ステップを提示する。
    /// launch 時のブロッキングを避けるため、ルーティングは `ContentView` 上の fullScreenCover で行う。
    @Published var onboardingCompleted: Bool?

    /// アプリ全体で共有する聴取ストリーク。未取得・未提供時は `nil`。
    @Published var listeningStreak: ListeningStreak?

    /// 直近のストリーク取得が 404 以外で失敗したか。
    @Published var listeningStreakLoadFailed = false

    /// プッシュ通知タップで開く対象 Podcast ID（ディープリンク・issue #80）。
    /// 設定されると Podcast タブへ遷移して再生する。遷移後は受け手が nil に戻す。
    @Published var selectedPodcastId: String?

    /// 直近の主体離脱の後始末が一部失敗したか（ios-slice-auth-01 / ios-contract-21.3）。全成功なら `nil`。
    @Published private(set) var lastCleanupIncomplete: CleanupIncomplete?

    /// 取得済みの APNs デバイストークン（16 進）。未取得なら `nil`。
    /// 資格情報ではないがログには出さない。認証確立後に backend へ登録する。
    private(set) var apnsDeviceToken: String?

    /// セッショントークンの保管先（既定は Keychain、テストはインメモリ）。
    private let sessionStore: SessionStore

    /// 起動時の設定の同期。本番は `PreferencesStore.refreshFromServer()`（合成 root が渡す）。
    private let refreshPreferences: () async -> Void

    /// 主体離脱時の設定の消去。本番は `PreferencesStore.clearSubjectScoped()`（合成 root が渡す）。
    private let clearSubjectPreferences: () -> Void

    /// ロック画面/コントロールセンターの表示クリア port（主体離脱の後始末で使う）。
    private let nowPlayingCenter: NowPlayingCenter

    /// 再生停止 port。`ContentView` が `registerPlaybackLifecycle(_:)` で登録する（weak）。
    private weak var playbackLifecycle: PlaybackLifecycle?

    /// 離脱主体の音声キャッシュ削除（主体離脱の後始末）。本番は `AudioCacheManager().removeSubject(_:)`。
    private let clearOfflineLibrary: (SubjectKey?) throws -> Void

    /// 音声ライブラリの束縛を現在の主体へ更新する。離脱では nil。
    private let bindOfflineSubject: (SubjectKey?) -> Void

    /// 起動時の回収。現在の主体以外の音声キャッシュと旧置き場を消す。
    private let reclaimOfflineLibrary: (SubjectKey?) throws -> Void

    /// ダウンロードの cancel 先。`ContentView` が `registerDownloads(_:)` で登録する（weak）。
    private weak var offlineDownloads: OfflineDownloads?

    /// 起動後に回収を済ませたか。起動単位の状態で、永続化しない。
    private var didReclaimOfflineLibrary = false

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

    /// 現在の設定から生成した ``APIClient``。優先順位: override > factory > 本番生成（D-3）。
    ///
    /// 生成時に読んだ保存トークンを unauthorized observer に捕捉させる（ios-contract-20.15）。
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
    /// - Parameter receipt: ログイン成功の結果（トークンと主体）。
    func completeLogin(_ receipt: LoginReceipt) {
        let previous = currentSubject
        sessionStore.token = receipt.token
        if let previous, isSameSubject(previous, receipt.subject) {
            // 同じ主体の再認証は離脱ではない。既存の主体キーは保ち、キーが初めて分かったときだけ束縛する。
            let incoming = receipt.subject
            session = .authenticated(Subject(
                username: incoming.username, displayName: incoming.displayName, role: incoming.role,
                key: incoming.key ?? previous.key))
            if previous.key == nil, let key = incoming.key { bindOfflineSubject(key) }
        } else {
            session = .authenticated(receipt.subject)
            bindOfflineSubject(receipt.subject.key)
            if let previous { runSubjectCleanup(departing: previous.key) }
        }
        reclaimOfflineLibraryOnce(keeping: currentSubject?.key)
        // ログイン直後、取得済みトークンがあれば backend に登録する。
        scheduleDeviceTokenRegistration()
    }

    /// `AccountSettingsView.saveProfile()` 等、AppState の外で await した後にプロフィールを
    /// 差し替える呼出元向けの API（ios-slice-auth-01）。`capturedAt` は await の前に捕捉した stamp。
    /// - Parameters:
    ///   - subject: 差し替え後の主体。
    ///   - stamp: await の前に捕捉した `subjectStamp`。
    func updateCurrentSubject(_ subject: Subject, capturedAt stamp: SubjectStamp) {
        guard isCurrentSubject(stamp) else { return }
        // プロフィール更新は主体キーを変えない。差し替え後の key が何であれ現在の key を保つ。
        session = .authenticated(Subject(
            username: subject.username, displayName: subject.displayName, role: subject.role,
            key: currentSubject?.key))
    }

    /// 同じ主体か。キーが両方あればキーの一致、どちらかが無ければ username の一致。
    private func isSameSubject(_ lhs: Subject, _ rhs: Subject) -> Bool {
        if let lhsKey = lhs.key, let rhsKey = rhs.key { return lhsKey == rhsKey }
        return lhs.username == rhs.username
    }

    /// `unavailable` から再解決を試みる（`retryResolve()`）。`unavailable` 以外からは no-op。
    func retryResolve() {
        guard case .unavailable = session else { return }
        session = .resolving
    }

    /// Authorization 付きリクエストが 401 を返したときに `APIClient` の observer から呼ばれる
    /// （ios-contract-20.7・ios-contract-20.8）。authenticated ∧ `sentToken` が保存トークンと一致するときだけ、
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
            reclaimOfflineLibraryOnce(keeping: nil)
            return
        }
        do {
            let user = try await apiClient.fetchMe()
            guard case .resolving = session, sessionStore.token == t0 else { return }
            let subject = user.toSubject()
            session = .authenticated(subject)
            bindOfflineSubject(subject.key)
            reclaimOfflineLibraryOnce(keeping: subject.key)
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
            reclaimOfflineLibraryOnce(keeping: nil)
        } catch let failure as ApiFailure {
            guard case .resolving = session, sessionStore.token == t0 else { return }
            session = .unavailable(failure)
        } catch {
            // ApiFailure 以外（キャンセル）は制御信号のため、状態・token とも変えない（A11）。
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

    /// ログアウトしてローカル状態を未認証にし、サーバ側セッションの破棄をベストエフォートで送る（G4）。
    ///
    /// 送信は破棄前のトークンで作った client に任せ、応答を待たない。通知登録の解除は
    /// セッション削除に連鎖する backend 側の責務で、client からは送らない。
    func logout() async {
        let departingClient = apiClient
        // 進行中のデバイストークン登録タスクをキャンセルし、logout 後にサーバへ登録リクエストが
        // 到達してトークン紐付けが復活する競合を防ぐ（issue #80 レビュー指摘）。
        deviceTokenRegistrationTask?.cancel()
        if case .authenticated = session {
            performLeaveProcessing()
        } else {
            sessionStore.token = nil
            session = .anonymous
        }
        Task { _ = try? await departingClient?.logout() }
    }

    /// 主体離脱（logout・失効の両方）の事後条件を実行する（spec §3.2）。呼出元は、呼ぶ直前に
    /// `session` が authenticated であることを確かめておくこと。
    private func performLeaveProcessing() {
        let departing = currentSubject?.key
        sessionStore.token = nil
        session = .anonymous
        bindOfflineSubject(nil)
        runSubjectCleanup(departing: departing)
    }

    /// 離脱主体の後始末を実行する。logout・401・主体の直接交代が同じ入口を使う。
    private func runSubjectCleanup(departing: SubjectKey?) {
        let cleanup = SubjectCleanup(
            playbackLifecycle: playbackLifecycle,
            nowPlayingCenter: nowPlayingCenter,
            clearSubjectPreferences: clearSubjectPreferences,
            clearOfflineLibrary: clearOfflineLibrary,
            cancelDownloads: { [weak self] in self?.offlineDownloads?.cancelAll() }
        )
        lastCleanupIncomplete = cleanup.run(departing: departing)
    }

    /// 起動後に主体が最初に確定した時点で 1 回だけ、現在の主体以外の音声キャッシュを回収する。
    /// 失敗は黙殺せず `lastCleanupIncomplete` に載せる。旗は戻さない（次回起動の回収が再実行する）。
    private func reclaimOfflineLibraryOnce(keeping key: SubjectKey?) {
        guard !didReclaimOfflineLibrary else { return }
        didReclaimOfflineLibrary = true
        do {
            try reclaimOfflineLibrary(key)
        } catch {
            lastCleanupIncomplete = CleanupIncomplete(failedParts: [.offlineLibrary])
        }
    }

    /// 登録済みの `PlaybackLifecycle` を差し替える（weak）。`ContentView` が表示時に呼ぶ（ios-contract-21.9）。
    /// - Parameter lifecycle: 再生停止の実処理を持つオブジェクト。
    func registerPlaybackLifecycle(_ lifecycle: PlaybackLifecycle) {
        playbackLifecycle = lifecycle
    }

    /// cancel 先の `OfflineDownloads` を登録する（weak）。未登録・解放済みなら後始末の cancel は何もしない。
    /// - Parameter downloads: 実行中のダウンロードを持つ use case。
    func registerDownloads(_ downloads: OfflineDownloads) {
        offlineDownloads = downloads
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

    /// API URL・キーはビルド注入値(Info.plist←Secrets.xcconfig)のみを読む（ADR-037、#25）。
    /// - Parameters:
    ///   - sessionStore: セッショントークンの保管先。既定は Keychain。テストで差し替える。
    ///   - apiClientOverride: テスト時に注入する ``APIClient``（既定 `nil`、最優先）。
    ///   - apiClientFactory: テスト seam（D-3）。保存トークンと observer から client を作る factory。
    ///   - refreshPreferences: 起動時の設定の同期。既定は何もしない。
    ///   - clearSubjectPreferences: 主体離脱時の設定の消去。既定は何もしない。
    ///   - nowPlayingCenter: ロック画面表示クリア port。既定は本番実装。
    ///   - clearOfflineLibrary: 離脱主体の音声キャッシュ削除。既定は `AudioCacheManager()` で主体のディレクトリだけを消す。
    ///   - bindOfflineSubject: 音声ライブラリの束縛。既定は何もしない。
    ///   - reclaimOfflineLibrary: 起動時の回収。既定は何もしない。
    init(
        sessionStore: SessionStore = KeychainSessionStore(),
        apiClientOverride: APIClient? = nil,
        apiClientFactory: ((String?, @escaping @MainActor () -> Void) -> APIClient)? = nil,
        refreshPreferences: @escaping () async -> Void = {},
        clearSubjectPreferences: @escaping () -> Void = {},
        nowPlayingCenter: NowPlayingCenter = MediaPlayerNowPlaying(),
        clearOfflineLibrary: @escaping (SubjectKey?) throws -> Void = { key in
            if let key { try AudioCacheManager().removeSubject(key) }
        },
        bindOfflineSubject: @escaping (SubjectKey?) -> Void = { _ in },
        reclaimOfflineLibrary: @escaping (SubjectKey?) throws -> Void = { _ in }
    ) {
        self.sessionStore = sessionStore
        self.apiClientOverride = apiClientOverride
        self.apiClientFactory = apiClientFactory
        self.refreshPreferences = refreshPreferences
        self.clearSubjectPreferences = clearSubjectPreferences
        self.nowPlayingCenter = nowPlayingCenter
        self.clearOfflineLibrary = clearOfflineLibrary
        self.bindOfflineSubject = bindOfflineSubject
        self.reclaimOfflineLibrary = reclaimOfflineLibrary
        // API URL・キーはビルド時注入のみ（ユーザー入力・UserDefaults フォールバックは廃止）。
        self.apiBaseURL = Self.injectedValue("APIBaseURL") ?? ""
        self.apiKey = Self.injectedValue("APIKey") ?? ""
    }
}
