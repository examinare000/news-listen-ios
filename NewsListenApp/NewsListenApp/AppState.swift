//
//  AppState.swift
//  NewsListenApp
//
//  誰であるかの確定（解決・失効・離脱・起動単位の回収）だけを持つ。
//  認証状態は `AuthSession`（ios-slice-auth-01）で表す。ユーザー設定の現在値は `PreferencesStore`、
//  通知の登録は `PushRegistration` が持つ。SwiftUI から @StateObject / @EnvironmentObject で参照する。
//

import Foundation
import Combine

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
/// UI 状態であり常にメインスレッドで更新されるため `@MainActor` にする。
@MainActor
final class AppState: ObservableObject {
    /// API の URL とキーがともに注入済みか。ビルド時注入（ADR-037）の結果を合成 root が渡す。実行時は不変。
    let isConfigured: Bool

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

    /// 直近の主体離脱の後始末が一部失敗したか（ios-slice-auth-01 / ios-contract-21.3）。全成功なら `nil`。
    @Published private(set) var lastCleanupIncomplete: CleanupIncomplete?

    /// セッショントークンの保管先（本番は Keychain、テストはインメモリ。合成 root・テストが渡す）。
    private let sessionStore: SessionStore

    /// 保存トークンと 401 の観測先から、認証の gateway を作る。作れないとき nil（合成 root が渡す）。
    private let accountGatewayFactory: (String?, @escaping @MainActor () -> Void) -> AccountGateway?

    /// 主体離脱時の設定の消去。本番は `PreferencesStore.clearSubjectScoped()`（合成 root が渡す）。
    private let clearSubjectPreferences: () -> Void

    /// ロック画面/コントロールセンターの表示クリア port（主体離脱の後始末で使う）。
    private let nowPlayingCenter: NowPlayingCenter

    /// 再生停止 port。`ContentView` が `registerPlaybackLifecycle(_:)` で登録する（weak）。
    private weak var playbackLifecycle: PlaybackLifecycle?

    /// 離脱主体の音声キャッシュ削除（主体離脱の後始末）。本番は合成 root が渡す。
    private let clearOfflineLibrary: (SubjectKey?) throws -> Void

    /// 音声ライブラリの束縛を現在の主体へ更新する。離脱では nil。
    private let bindOfflineSubject: (SubjectKey?) -> Void

    /// 起動時の回収。現在の主体以外の音声キャッシュと旧置き場を消す。
    private let reclaimOfflineLibrary: (SubjectKey?) throws -> Void

    /// 離脱主体の端末の位置の記録の削除（主体離脱の後始末）。未送信も送らずに消す。
    private let clearPositionRecords: (SubjectKey?) throws -> Void

    /// 起動時の回収。現在の主体以外の位置の記録を消す。
    private let reclaimPositionRecords: (SubjectKey?) throws -> Void

    /// ダウンロードの cancel 先。`ContentView` が `registerDownloads(_:)` で登録する（weak）。
    private weak var offlineDownloads: OfflineDownloads?

    /// 起動後に回収を済ませたか。起動単位の状態で、永続化しない。
    private var didReclaimOfflineLibrary = false

    /// logout が呼ぶ、通知の登録の cancel。本番は `PushRegistration.cancelPendingRegistration()`（合成 root が渡す）。
    private let cancelPushRegistration: () -> Void

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

    /// 401 の観測先。`APIClient` の `onUnauthorized` に渡し、`sentToken` はそのリクエストに使ったトークン。
    /// `AppState.swift` の外（合成 root）に `.unauthorized` を書かせないための入口。
    func sessionExpiryObserver(sentToken: String?) -> @MainActor () -> Void {
        { [weak self] in self?.handle(failure: .unauthorized, sentToken: sentToken) }
    }

    /// 保存済みトークンで `/auth/me` を解決し、認証状態を確定する（G1・G2）。
    ///
    /// 未設定・トークン無しは anonymous。開始時に捕捉した `t0` と、await の後の
    /// `session == .resolving ∧ 保存トークン == t0` の両方を満たすときだけ結果を書く
    /// （前の主体の遅延応答が後発の主体を書き換えない: G-S2-12）。
    /// - Returns: この呼出が authenticated へ遷移させたときだけ true。後続の起動手順（`LaunchSequence`）を起こす合図。
    @discardableResult
    func resolve() async -> Bool {
        guard case .resolving = session else { return false }
        let t0 = sessionStore.token
        guard let t0, let gateway = accountGatewayFactory(t0, sessionExpiryObserver(sentToken: t0)) else {
            session = .anonymous
            reclaimOfflineLibraryOnce(keeping: nil)
            return false
        }
        do {
            let subject = try await gateway.fetchMe()
            guard case .resolving = session, sessionStore.token == t0 else { return false }
            session = .authenticated(subject)
            bindOfflineSubject(subject.key)
            reclaimOfflineLibraryOnce(keeping: subject.key)
            return true
        } catch ApiFailure.unauthorized {
            guard case .resolving = session, sessionStore.token == t0 else { return false }
            sessionStore.token = nil
            session = .anonymous
            reclaimOfflineLibraryOnce(keeping: nil)
            return false
        } catch let failure as ApiFailure {
            guard case .resolving = session, sessionStore.token == t0 else { return false }
            session = .unavailable(failure)
            return false
        } catch {
            // ApiFailure 以外（キャンセル）は制御信号のため、状態・token とも変えない（A11）。
            return false
        }
    }

    /// ログアウトしてローカル状態を未認証にし、サーバ側セッションの破棄をベストエフォートで送る（G4）。
    ///
    /// 送信は破棄前のトークンで作った gateway に任せ、応答を待たない。通知登録の解除は
    /// セッション削除に連鎖する backend 側の責務で、client からは送らない。
    func logout() async {
        let token = sessionStore.token
        let departingGateway = accountGatewayFactory(token, sessionExpiryObserver(sentToken: token))
        // 進行中のデバイストークン登録をキャンセルし、logout 後にサーバへ登録リクエストが
        // 到達してトークン紐付けが復活する競合を防ぐ（issue #80 レビュー指摘）。
        cancelPushRegistration()
        if case .authenticated = session {
            performLeaveProcessing()
        } else {
            sessionStore.token = nil
            session = .anonymous
        }
        Task { _ = try? await departingGateway?.logout() }
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
            cancelDownloads: { [weak self] in self?.offlineDownloads?.cancelAll() },
            clearPositionRecords: clearPositionRecords
        )
        lastCleanupIncomplete = cleanup.run(departing: departing)
    }

    /// 起動後に主体が最初に確定した時点で 1 回だけ、現在の主体以外の音声キャッシュと位置の記録を、互いに独立に回収する。
    /// 失敗は黙殺せず `lastCleanupIncomplete` に載せる。旗は戻さない（次回起動の回収が再実行する）。
    private func reclaimOfflineLibraryOnce(keeping key: SubjectKey?) {
        guard !didReclaimOfflineLibrary else { return }
        didReclaimOfflineLibrary = true
        var failedParts: [SubjectCleanupFailedPart] = []
        do {
            try reclaimOfflineLibrary(key)
        } catch {
            failedParts.append(.offlineLibrary)
        }
        do {
            try reclaimPositionRecords(key)
        } catch {
            failedParts.append(.positionRecords)
        }
        if !failedParts.isEmpty {
            lastCleanupIncomplete = CleanupIncomplete(failedParts: failedParts)
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

    /// - Parameters:
    ///   - sessionStore: セッショントークンの保管先。Keychain とインメモリは合成 root・テストが選ぶ。
    ///   - accountGatewayFactory: 保存トークンと 401 の観測先から認証の gateway を作る。作れないとき nil（`resolve()` は `.anonymous` に落ちる）。
    ///   - isConfigured: API の URL とキーがともに注入済みか。初期設定画面の出し分けに使う。
    ///   - clearSubjectPreferences: 主体離脱時の設定の消去。既定は何もしない。
    ///   - nowPlayingCenter: ロック画面表示クリア port。
    ///   - clearOfflineLibrary: 離脱主体の音声キャッシュ削除。
    ///   - bindOfflineSubject: 音声ライブラリの束縛。既定は何もしない。
    ///   - reclaimOfflineLibrary: 起動時の回収。既定は何もしない。
    ///   - cancelPushRegistration: logout が呼ぶ通知の登録の cancel。既定は何もしない。
    init(
        sessionStore: SessionStore,
        accountGatewayFactory: @escaping (String?, @escaping @MainActor () -> Void) -> AccountGateway?,
        isConfigured: Bool = false,
        clearSubjectPreferences: @escaping () -> Void = {},
        nowPlayingCenter: NowPlayingCenter,
        clearOfflineLibrary: @escaping (SubjectKey?) throws -> Void,
        bindOfflineSubject: @escaping (SubjectKey?) -> Void = { _ in },
        reclaimOfflineLibrary: @escaping (SubjectKey?) throws -> Void = { _ in },
        clearPositionRecords: @escaping (SubjectKey?) throws -> Void = { _ in },
        reclaimPositionRecords: @escaping (SubjectKey?) throws -> Void = { _ in },
        cancelPushRegistration: @escaping () -> Void = {}
    ) {
        self.sessionStore = sessionStore
        self.accountGatewayFactory = accountGatewayFactory
        self.isConfigured = isConfigured
        self.clearSubjectPreferences = clearSubjectPreferences
        self.nowPlayingCenter = nowPlayingCenter
        self.clearOfflineLibrary = clearOfflineLibrary
        self.bindOfflineSubject = bindOfflineSubject
        self.reclaimOfflineLibrary = reclaimOfflineLibrary
        self.clearPositionRecords = clearPositionRecords
        self.reclaimPositionRecords = reclaimPositionRecords
        self.cancelPushRegistration = cancelPushRegistration
    }
}
