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
    /// アプリ全体で共有する設定状態。ロック画面 port は再生 ViewModel と同じ 1 個を共有する。
    @StateObject private var appState = AppState(
        nowPlayingCenter: NewsListenAppApp.nowPlayingCenter,
        clearOfflineLibrary: { @MainActor in try NewsListenAppApp.offlineLibrary.clearAll() }
    )

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
                        if let client = appState.apiClient {
                            LoginView(apiClient: client) { appState.completeLogin($0) }
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
                                defaultSpeed: { Float(appState.defaultPlaybackSpeed) },
                                audioEngine: Self.audioEngine,
                                nowPlayingCenter: Self.nowPlayingCenter,
                                library: Self.offlineLibrary
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

    /// 設定画面に渡す保存庫（App が作った 1 個）。
    private let library: OfflineLibrary

    /// ビューを生成する。
    /// - Parameters:
    ///   - apiClient: 再生 ViewModel に注入する API クライアント。
    ///   - refreshListeningStreak: 完聴時に共有ストリークを更新するクロージャ。
    ///   - defaultSpeed: 既定の再生速度（`appState` に依るので呼ぶ側が closure にして渡す）。
    ///   - audioEngine: 再生エンジン（App がプロセスで 1 個作ったもの）。
    ///   - nowPlayingCenter: ロック画面 port（同上）。
    ///   - library: 保存庫（同上）。
    /// - Note: `@MainActor` 化した `NetworkMonitor` の生成を分離文脈で行うため、
    ///   ビューの init も `@MainActor` にする（旧 PodcastView.init と同じ理由）。
    @MainActor
    init(
        apiClient: APIClient,
        refreshListeningStreak: @escaping @MainActor () async -> Void,
        defaultSpeed: @escaping () -> Float,
        audioEngine: any AudioEngine,
        nowPlayingCenter: NowPlayingCenter,
        library: OfflineLibrary
    ) {
        self.library = library
        // `init` は再描画のたびに走るので、組み立ては `StateObject` の autoclosure の中（1 回だけ評価される）で行う。
        _playerViewModel = StateObject(
            wrappedValue: Self.makePlayerViewModel(
                apiClient: apiClient,
                refreshListeningStreak: refreshListeningStreak,
                defaultSpeed: defaultSpeed,
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
        engine: any AudioEngine,
        nowPlayingCenter: NowPlayingCenter,
        library: OfflineLibrary
    ) -> PodcastViewModel {
        let gateway = PlaybackGateway.live(apiClient: apiClient)
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
            downloadAudio: gateway.downloadAudio
        )
        let playerViewModel = PodcastViewModel(
            apiClient: apiClient,
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
            apiTab("フィード", systemImage: "newspaper", tag: 0) { client in
                FeedView(apiClient: client)
            }
            apiTab("Podcast", systemImage: "headphones", tag: 1) { _ in
                PodcastView(viewModel: playerViewModel)
            }
            apiTab("スター", systemImage: "star", tag: 2) { client in
                StarredView(apiClient: client)
            }
            // 学習は第 3 タブ（iOS 慣習: 学習機能は追加タブ）。
            apiTab("学習", systemImage: "book.closed", tag: 3) { client in
                LearningView(apiClient: client)
            }
            // Settings は API 未設定の修正導線として常に表示する（第 4 タブ末尾）。
            // apiClient が nil でも難易度・API 設定は編集可能（RSS 操作のみ無効）。
            SettingsView(appState: appState, library: library)
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
            await appState.refreshOnboardingStatus()
            await appState.refreshListeningStreak()
        }
        // 主体離脱時の再生停止 port を登録する（ios-slice-auth-01 / ios-contract-21.9。実体は `PlaybackCoordinator`）。
        .onAppear { appState.registerPlaybackLifecycle(playerViewModel.playbackLifecycle) }
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
            OnboardingSourcesView(apiClient: appState.apiClient)
                .environmentObject(appState)
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

    /// `onboardingCompleted == false`（明示的に未完了）のときだけ追加ステップを提示する Binding。
    /// 取得前(`nil`) は提示しない。閉じる操作は `OnboardingSourcesView` 側の completeOnboarding に委ねる。
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { appState.onboardingCompleted == false },
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
