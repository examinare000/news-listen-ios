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

    /// APNs プッシュ通知（issue #80）の AppDelegate。純 SwiftUI ライフサイクルに接続する。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
                        ContentView()
                    }
                }
            }
            .environmentObject(appState)
            // AppDelegate に AppState を注入し、保留中のトークン/通知遷移を反映させる。
            .onAppear { appDelegate.appState = appState }
        }
    }
}

/// メインのタブビュー。フィード / Podcast / 設定の3タブを表示する。
struct ContentView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    /// タブ選択。通知タップ時に Podcast タブ（tag 1）へ切り替えるため保持する。
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // ContentView は isConfigured 時のみ表示されるため apiClient は通常非 nil。
            // URL 不正など稀な nil 時はセットアップ確認を促す。
            if let client = appState.apiClient {
                FeedView(apiClient: client)
                    .tabItem { Label("フィード", systemImage: "newspaper") }
                    .tag(0)
            } else {
                ContentUnavailableView(
                    "API 設定を確認してください",
                    systemImage: "exclamationmark.triangle",
                    description: Text("設定タブで API URL とキーを確認してください")
                )
                .tabItem { Label("フィード", systemImage: "newspaper") }
                .tag(0)
            }
            if let client = appState.apiClient {
                PodcastView(apiClient: client)
                    .tabItem { Label("Podcast", systemImage: "headphones") }
                    .tag(1)
            } else {
                ContentUnavailableView(
                    "API 設定を確認してください",
                    systemImage: "exclamationmark.triangle",
                    description: Text("設定タブで API URL とキーを確認してください")
                )
                .tabItem { Label("Podcast", systemImage: "headphones") }
                .tag(1)
            }
            // Settings は API 未設定の修正導線として常に表示する。
            // apiClient が nil でも難易度・API 設定は編集可能（RSS 操作のみ無効）。
            SettingsView(apiClient: appState.apiClient)
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(2)
        }
        // 通知タップで遷移先 Podcast が指定されたら Podcast タブへ切り替える。
        // 実際の再生は PodcastView 側が selectedPodcastId を監視して行う。
        .onChange(of: appState.selectedPodcastId) { _, newValue in
            if newValue != nil { selectedTab = 1 }
        }
        // 起動ごとに onboarding 状態を取得し、未完了なら追加ステップを被せる。
        // 3分岐ルーティングではなく cover にすることで launch をブロックしない。
        .task { await appState.refreshOnboardingStatus() }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingSourcesView()
                .environmentObject(appState)
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
