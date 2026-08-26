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
    /// アプリ全体で共有する設定状態。
    @StateObject private var appState = AppState()

    /// MetricKit クラッシュ診断の購読者（issue #83）。購読を維持するため保持する。
    private static let crashReporter = CrashReporter()

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
                    switch appState.authStatus {
                    case .unknown:
                        // 保存済みトークンで /auth/me を解決する間のローディング。
                        ProgressView("認証を確認中…")
                            .task { await appState.refreshAuth() }
                    case .unauthenticated:
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
                                refreshListeningStreak: { await appState.refreshListeningStreak() }
                            )
                        } else {
                            ContentUnavailableView(
                                "API 設定を確認してください",
                                systemImage: "exclamationmark.triangle",
                                description: Text("接続先 URL が不正です")
                            )
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

    /// ビューを生成する。
    /// - Parameters:
    ///   - apiClient: 再生 ViewModel に注入する API クライアント。
    ///   - refreshListeningStreak: 完聴時に共有ストリークを更新するクロージャ。
    /// - Note: `@MainActor` 化した `NetworkMonitor` の既定値生成を分離文脈で行うため、
    ///   ビューの init も `@MainActor` にする（旧 PodcastView.init と同じ理由）。
    @MainActor
    init(
        apiClient: APIClient,
        refreshListeningStreak: @escaping @MainActor () async -> Void
    ) {
        _playerViewModel = StateObject(
            wrappedValue: PodcastViewModel(
                apiClient: apiClient,
                refreshListeningStreak: refreshListeningStreak
            )
        )
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
            SettingsView(appState: appState)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(4)
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await appState.refreshListeningStreak() }
            case .background, .inactive:
                // タブ離脱で stopPlayback() を呼ばなくなったため、アプリ離脱直前の
                // 再生位置をここで同期する（15秒毎の定期同期の取りこぼし補完）。
                playerViewModel.flushPlaybackPosition()
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
        await playerViewModel.playById(id)
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

    /// `onboardingCompleted == false`（明示的に未完了）のときだけ追加ステップを提示する Binding。
    /// 取得前(`nil`) は提示しない。閉じる操作は `OnboardingSourcesView` 側の completeOnboarding に委ねる。
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { appState.onboardingCompleted == false },
            set: { _ in }
        )
    }
}
