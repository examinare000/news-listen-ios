//
//  NewsListenAppApp.swift
//  NewsListenApp
//
//  @main エントリポイント。API 設定はビルド時注入のため、未注入なら設定不備の案内、
//  注入済みなら認証状態に応じてタブビュー（フィード / Podcast / 設定）を表示する。
//

import SwiftUI

/// アプリの `@main` エントリポイント。
///
/// API URL・キーはビルド時注入（Secrets.xcconfig→Info.plist、ADR-037）。
/// ``AppState/isConfigured`` が偽（注入漏れ）なら設定不備の案内、真なら認証状態に応じて
/// ローディング → ログイン → タブビューの順にゲートする。
@main
struct NewsListenAppApp: App {
    /// アプリ全体で共有する認証状態。ロック画面 port は再生 ViewModel と同じ 1 個を共有する。
    @StateObject private var appState: AppState
    /// 設定の現在値の持ち主。`init()` で `AppState` と相互に結ぶ（ios-dec-92）。
    @StateObject private var preferencesStore: PreferencesStore

    /// `PreferencesStore` と `AppState` は互いの closure を必要とする。構築の順序を、後から結ぶ弱参照の箱で解く。
    private final class AppStateBox {
        weak var state: AppState?
    }

    /// `body` が `ContentView` へ渡す closure の解決先。`init()` で結んだ箱を保持する。
    private let box: AppStateBox
    /// ログインの手順（状態を持たないので App が持ち続けて害は無い）。
    private let authentication: Authentication
    private let passkeySignIn: PasskeySignIn
    /// Passkey の認証器。ログインと登録で同じ 1 個を使う（同時には使わない）。
    private let passkeyProvider: PasskeyAuthorizationProviding

    /// MetricKit クラッシュ診断の購読者（issue #83）。購読を維持するため保持する。
    private static let crashReporter = CrashReporter()

    /// 再生エンジンとロック画面 port。プロセスで 1 個ずつ作る（App の init が何回呼ばれても同じインスタンス）。
    private static let audioEngine = AVPlayerEngine()
    private static let nowPlayingCenter = MediaPlayerNowPlaying()
    /// 保存済み音声の保存庫。プロセスで 1 個作り、再生・ダウンロード・設定の全員が同じ集合を見る。
    private static let offlineLibrary = OfflineLibrary(store: .live(cacheManager: AudioCacheManager()))

    /// APNs プッシュ通知（issue #80）の AppDelegate。純 SwiftUI ライフサイクルに接続する。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// グローバル外観（ナビゲーション見出しのセリフ化・紙背景）を起動時に一度だけ設定する。
    /// あわせて MetricKit のクラッシュ診断購読を開始する（次回起動時に前回クラッシュが配信される）。
    init() {
        DSAppearance.configure()
        Self.crashReporter.register()

        let box = AppStateBox()
        let store = PreferencesStore(
            gateway: .live(client: { box.state?.apiClient }),
            storage: .live(registry: PreferenceRegistry()),
            isCurrentSubject: { box.state?.isCurrentSubject($0) ?? false },
            subjectStamp: { box.state!.subjectStamp },
            isAuthenticated: { box.state?.currentSubject != nil }
        )
        let state = AppState(
            refreshPreferences: { await store.refreshFromServer() },
            clearSubjectPreferences: { store.clearSubjectScoped() },
            nowPlayingCenter: Self.nowPlayingCenter,
            clearOfflineLibrary: { @MainActor key in try Self.offlineLibrary.remove(subject: key) },
            bindOfflineSubject: { @MainActor key in Self.offlineLibrary.bind(subject: key) },
            reclaimOfflineLibrary: { @MainActor key in try Self.offlineLibrary.reclaim(keeping: key) }
        )
        box.state = state
        _appState = StateObject(wrappedValue: state)
        _preferencesStore = StateObject(wrappedValue: store)
        self.box = box
        let accountGateway = AccountGateway.live(client: { box.state?.apiClient })
        let passkeyProvider = ASAuthorizationPasskeyProvider()
        self.authentication = Authentication(gateway: accountGateway)
        self.passkeySignIn = PasskeySignIn(gateway: accountGateway, provider: passkeyProvider)
        self.passkeyProvider = passkeyProvider
        DSFeedback.shared.isSoundEnabled = { store.soundEnabled }
        DSFeedback.shared.isHapticsEnabled = { store.hapticsEnabled }
    }

    /// 設定状態・認証状態に応じてルート画面を出し分けるシーン。
    ///
    /// 注入漏れ → 設定不備案内、注入済みで認証未解決 → ローディング、未ログイン → ログイン、
    /// ログイン済み → タブビュー、の順にゲートする。
    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.isConfigured {
                    // API 設定はビルド時注入のみ。未注入はビルド構成の不備であり、
                    // ユーザーが端末上で修正する導線は持たない（Secrets.xcconfig で設定する）。
                    ContentUnavailableView(
                        "API 設定が未注入です",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Secrets.xcconfig（API_BASE_URL / API_KEY）をビルド時に設定してください")
                    )
                } else {
                    switch appState.session {
                    case .resolving:
                        // 保存済みトークンで /auth/me を解決する間のローディング。
                        ProgressView("認証を確認中…")
                            .task { await appState.refreshAuth() }
                    case .anonymous:
                        if appState.apiClient != nil {
                            LoginView(authentication: authentication, passkeySignIn: passkeySignIn) { appState.completeLogin($0) }
                        } else {
                            ContentUnavailableView(
                                "API 設定を確認してください",
                                systemImage: "exclamationmark.triangle",
                                description: Text("接続先 URL が不正です")
                            )
                        }
                    case .authenticated:
                        if let client = appState.apiClient {
                            ContentView(
                                apiClient: client,
                                refreshListeningStreak: { await appState.refreshListeningStreak() },
                                defaultSpeed: { Float(preferencesStore.defaultPlaybackSpeed) },
                                currentSubjectKey: { appState.currentSubject?.key },
                                audioEngine: Self.audioEngine,
                                nowPlayingCenter: Self.nowPlayingCenter,
                                library: Self.offlineLibrary,
                                passkeyProvider: passkeyProvider,
                                currentUsername: { box.state?.currentSubject?.username },
                                currentClient: { box.state?.apiClient },
                                subjectStamp: { box.state!.subjectStamp },
                                isCurrentSubject: { box.state?.isCurrentSubject($0) ?? false }
                            )
                        } else {
                            ContentUnavailableView(
                                "API 設定を確認してください",
                                systemImage: "exclamationmark.triangle",
                                description: Text("接続先 URL が不正です")
                            )
                        }
                    case .unavailable:
                        // ios-slice-auth-01: 認証解決の失敗（トークンは保持）。再試行導線を出す（UV-1）。
                        ContentUnavailableView {
                            Label("認証を確認できません", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("通信状態を確認して再試行してください")
                        } actions: {
                            Button("再試行") { appState.retryResolve() }
                        }
                    }
                }
            }
            .tint(DSColor.accent)
            .environmentObject(appState)
            .environmentObject(preferencesStore)
            // AppDelegate に AppState を注入し、保留中のトークン/通知遷移を反映させる。
            .onAppear { appDelegate.appState = appState }
        }
    }
}

/// メインのタブビュー。フィード / Podcast / スター / 設定 / 学習の5タブを表示する。
struct ContentView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    /// タブ選択。通知タップ時に Podcast タブ（tag 1）へ切り替えるため保持する。
    @State private var selectedTab = 0
    /// foreground 復帰時に共有ストリークを更新するためのライフサイクル状態。
    @Environment(\.scenePhase) private var scenePhase

    /// 全タブで共有する再生 ViewModel。
    ///
    /// PodcastView の `@StateObject` 所有だとタブ切替の onDisappear で再生を止めるしか
    /// なかったため、ContentView へ引き上げてタブ間で再生を継続させる（Podcast タブ以外
    /// でもバックグラウンド再生・ロック画面操作が生きる）。
    @StateObject private var playerViewModel: PodcastViewModel

    /// フィード・設定の残り回数が共有する、一覧・保留・確定の application。authenticated の間だけ生きる。
    @StateObject private var curation: FeedCuration
    /// Star 一覧の application。`ObservableObject` ではないので `@State` で最初の 1 つを保つ。
    @State private var starred: StarredArticles
    /// RSS ソースの操作とおすすめの application。authenticated の間だけ生きる。
    @State private var sources: SourceSubscriptions
    /// 初回 Onboarding の完了の状態。logout で `ContentView` ごと外れ、次の主体は nil から始まる。
    @StateObject private var onboarding: OnboardingProgress

    /// 設定画面に渡す保存庫（App が作った 1 個）。
    private let library: OfflineLibrary
    /// アカウント欄の手順。authenticated の間だけ生きる（logout で `ContentView` ごと外れる）。
    @State private var accountProfile: AccountProfile
    @State private var deviceSessions: DeviceSessions
    @State private var passkeyEnrollment: PasskeyEnrollment
    @State private var userAdministration: UserAdministration

    /// ビューを生成する。
    /// - Parameters:
    ///   - apiClient: 再生 ViewModel に注入する API クライアント。
    ///   - refreshListeningStreak: 完聴時に共有ストリークを更新するクロージャ。
    ///   - defaultSpeed: 既定の再生速度（`appState` に依るので呼ぶ側が closure にして渡す）。
    ///   - currentSubjectKey: ダウンロードの開始時に固定する現在の主体キー（`defaultSpeed` と同じ形で渡す）。
    ///   - audioEngine: 再生エンジン（App がプロセスで 1 個作ったもの）。
    ///   - nowPlayingCenter: ロック画面 port（同上）。
    ///   - library: 保存庫（同上）。
    ///   - passkeyProvider: Passkey の認証器（App が作った 1 個。登録の手順に渡す）。
    ///   - currentUsername: 現在の主体のユーザー名（管理画面で自分の行を判定する。呼ぶたびに読む）。
    ///   - currentClient: 呼出のたびに現在の API クライアントを返す（トークンは呼出の時点のもの）。
    ///   - subjectStamp: 現在の主体の照合値を捕捉する。
    ///   - isCurrentSubject: 捕捉した照合値が今も現在の主体か。
    /// - Note: `@MainActor` 化した `NetworkMonitor` の生成を分離文脈で行うため、
    ///   ビューの init も `@MainActor` にする（旧 PodcastView.init と同じ理由）。
    @MainActor
    init(
        apiClient: APIClient,
        refreshListeningStreak: @escaping @MainActor () async -> Void,
        defaultSpeed: @escaping () -> Float,
        currentSubjectKey: @escaping () -> SubjectKey?,
        audioEngine: any AudioEngine,
        nowPlayingCenter: NowPlayingCenter,
        library: OfflineLibrary,
        passkeyProvider: PasskeyAuthorizationProviding,
        currentUsername: @escaping () -> String?,
        currentClient: @escaping @MainActor () -> APIClient?,
        subjectStamp: @escaping () -> SubjectStamp,
        isCurrentSubject: @escaping (SubjectStamp) -> Bool
    ) {
        self.library = library
        // `init` は再描画のたびに走るが、`@StateObject`／`@State` が最初の 1 つだけを保つ。
        let gateway = CurationGateway.live(client: { apiClient })
        _curation = StateObject(wrappedValue: FeedCuration(gateway: gateway, undoGracePeriod: .seconds(4), currentSubject: currentSubjectKey))
        _starred = State(wrappedValue: StarredArticles(gateway: gateway))
        _sources = State(wrappedValue: SourceSubscriptions(gateway: SourcesGateway.live(client: currentClient)))
        let accountGateway = AccountGateway.live(client: currentClient)
        _accountProfile = State(wrappedValue: AccountProfile(gateway: accountGateway))
        _deviceSessions = State(wrappedValue: DeviceSessions(gateway: accountGateway))
        _passkeyEnrollment = State(wrappedValue: PasskeyEnrollment(gateway: accountGateway, provider: passkeyProvider))
        _userAdministration = State(wrappedValue: UserAdministration(gateway: accountGateway, currentUsername: currentUsername))
        _onboarding = StateObject(wrappedValue: OnboardingProgress.live(client: currentClient, subjectStamp: subjectStamp, isCurrentSubject: isCurrentSubject))
        // 再生 ViewModel の組み立ては `StateObject` の autoclosure の中（1 回だけ評価される）で行う。
        _playerViewModel = StateObject(
            wrappedValue: Self.makePlayerViewModel(
                apiClient: apiClient,
                refreshListeningStreak: refreshListeningStreak,
                defaultSpeed: defaultSpeed,
                currentSubjectKey: currentSubjectKey,
                engine: audioEngine,
                nowPlayingCenter: nowPlayingCenter,
                library: library
            )
        )
    }

    /// 再生の入口（gateway・Reporter・Coordinator・ダウンロード・facade）を 1 組作る。
    @MainActor
    private static func makePlayerViewModel(
        apiClient: APIClient,
        refreshListeningStreak: @escaping @MainActor () async -> Void,
        defaultSpeed: @escaping () -> Float,
        currentSubjectKey: @escaping () -> SubjectKey?,
        engine: any AudioEngine,
        nowPlayingCenter: NowPlayingCenter,
        library: OfflineLibrary
    ) -> PodcastViewModel {
        let gateway = PlaybackGateway.live(apiClient: apiClient)
        let learningGateway = LearningGateway.live(apiClient: apiClient)
        let catalog = EpisodeCatalog(gateway: .live(apiClient: apiClient))
        let networkMonitor = NetworkMonitor()
        let reporter = PositionReporter(
            updatePosition: gateway.updatePosition,
            markCompleted: gateway.markCompleted,
            onPositionSaved: { episode in catalog.applyPositionSaved(episode) },
            onCompletionRecorded: refreshListeningStreak,
            beginBackgroundTask: { beginBackgroundTask() }
        )
        let coordinator = PlaybackCoordinator(
            engine: engine,
            nowPlayingCenter: nowPlayingCenter,
            library: library,
            reporter: reporter,
            fetchEpisode: gateway.fetchEpisode,
            isOnline: { networkMonitor.isOnline },
            defaultSpeed: defaultSpeed,
            lockScreenSubtitle: { DifficultyLabel.text(for: $0) },
            beginBackgroundTask: { beginBackgroundTask() }
        )
        let downloads = OfflineDownloads(
            library: library,
            fetchEpisode: gateway.fetchEpisode,
            downloadAudio: gateway.downloadAudio,
            currentSubject: currentSubjectKey
        )
        let playerViewModel = PodcastViewModel(
            vocabularyBook: VocabularyBook(gateway: learningGateway),
            quizGrading: QuizGrading(gateway: learningGateway),
            catalog: catalog,
            coordinator: coordinator,
            reporter: reporter,
            library: library,
            downloads: downloads,
            networkMonitor: networkMonitor,
            defaultSpeed: defaultSpeed
        )
        return playerViewModel
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            apiTab("フィード", systemImage: "newspaper", tag: 0) { _ in
                FeedView(curation: curation)
            }
            apiTab("Podcast", systemImage: "headphones", tag: 1) { _ in
                PodcastView(viewModel: playerViewModel)
            }
            apiTab("スター", systemImage: "star", tag: 2) { _ in
                StarredView(starred: starred)
            }
            // 学習は第 3 タブ（iOS 慣習: 学習機能は追加タブ）。
            apiTab("学習", systemImage: "book.closed", tag: 3) { client in
                LearningView(apiClient: client)
            }
            // Settings は API 未設定の修正導線として常に表示する（第 4 タブ末尾）。
            // apiClient が nil でも難易度・API 設定は編集可能（RSS 操作のみ無効）。
            SettingsView(
                appState: appState,
                library: library,
                downloads: playerViewModel.downloads,
                curation: curation,
                sources: sources,
                profile: accountProfile,
                deviceSessions: deviceSessions,
                enrollment: passkeyEnrollment,
                administration: userAdministration
            )
                .withMiniPlayer(playerViewModel)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(4)
        }
        // フルプレイヤーはタブ内カードではなくグローバルシート。下スワイプ（interactive
        // dismiss）＝最小化としてミニプレイヤーへ落とす（hidden にはしない）。
        .sheet(isPresented: playerSheetBinding) {
            PlayerSheetView(vm: playerViewModel)
        }
        // 通知タップで遷移先 Podcast が指定されたら Podcast タブへ切り替えて再生する。
        // .task(id:) はマウント時にも発火するため、コールドスタート（ContentView 生成前に
        // selectedPodcastId が確定済み）でも初期値を拾える（onChange はマウント済みの変化のみで取りこぼす）。
        // 再生 ViewModel を ContentView が所有するため、PodcastView のマウントに依存せず消費できる。
        .task(id: appState.selectedPodcastId) { await consumeDeepLink() }
        // 起動ごとに onboarding 状態を取得し、未完了なら追加ステップを被せる。
        // 3分岐ルーティングではなく cover にすることで launch をブロックしない。
        .task {
            await onboarding.refresh()
            await appState.refreshListeningStreak()
        }
        // 主体離脱時の再生停止 port を登録する（ios-slice-auth-01 / ios-contract-21.9。実体は `PlaybackCoordinator`）。
        .onAppear {
            appState.registerPlaybackLifecycle(playerViewModel.playbackLifecycle)
            appState.registerDownloads(playerViewModel.downloads)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await appState.refreshListeningStreak() }
            case .background, .inactive:
                // タブ離脱で再生を止めなくなったため、アプリ離脱直前の
                // 再生位置をここで同期する（15秒毎の定期同期の取りこぼし補完）。
                playerViewModel.flushPosition()
            @unknown default:
                break
            }
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingSourcesView(sources: sources, onboarding: onboarding)
        }
    }

    /// 通知ディープリンクで指定された Podcast へタブを切り替えて再生し、消費後に状態をクリアする。
    private func consumeDeepLink() async {
        guard let id = appState.selectedPodcastId else { return }
        selectedTab = 1
        await playerViewModel.startEpisode(id: id)
        // await 中に新しい通知タップで id が変わり得るため、自分が消費した id のときだけクリアする。
        if appState.selectedPodcastId == id {
            appState.selectedPodcastId = nil
        }
    }

    /// API 必須タブの稀な client=nil 表示を一元化し、タブ追加で分岐を複製しない。
    @ViewBuilder
    private func apiTab<Content: View>(
        _ title: String,
        systemImage: String,
        tag: Int,
        @ViewBuilder content: (APIClient) -> Content
    ) -> some View {
        if let client = appState.apiClient {
            content(client)
                .withMiniPlayer(playerViewModel)
                .tabItem { Label(title, systemImage: systemImage) }
                .tag(tag)
        } else {
            ContentUnavailableView(
                "API 設定を確認してください",
                systemImage: "exclamationmark.triangle",
                description: Text("ビルド時の API URL とキーを確認してください")
            )
            .tabItem { Label(title, systemImage: systemImage) }
            .tag(tag)
        }
    }

    /// フルプレイヤーシートの表示 Binding。閉じる操作（下スワイプ含む）は最小化として扱う。
    private var playerSheetBinding: Binding<Bool> {
        Binding(
            get: { playerViewModel.presentation == .expanded },
            set: { if !$0 { playerViewModel.minimizePlayer() } }
        )
    }

    /// `isCompleted == false`（明示的に未完了）のときだけ追加ステップを提示する Binding。
    /// 取得前(`nil`) は提示しない。閉じる操作は `OnboardingSourcesView` 側の完了の記録に委ねる。
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { onboarding.isCompleted == false },
            set: { _ in }
        )
    }
}

/// 完聴の送信などを、アプリが一時的にバックグラウンドへ回っても走り切らせる保護。返す closure で終える。
/// `UIBackgroundModes` は audio のみのため、期限切れの処理は持たないベストエフォート。
@MainActor
private func beginBackgroundTask() -> () -> Void {
    let task = UIApplication.shared.beginBackgroundTask()
    return {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}
