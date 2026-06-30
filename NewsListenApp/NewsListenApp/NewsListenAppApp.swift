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
                        ContentView()
                    }
                }
            }
            .tint(DSColor.accent)
            .environmentObject(appState)
        }
    }
}

/// メインのタブビュー。フィード / Podcast / 設定の3タブを表示する。
struct ContentView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            // ContentView は isConfigured 時のみ表示されるため apiClient は通常非 nil。
            // URL 不正など稀な nil 時はセットアップ確認を促す。
            if let client = appState.apiClient {
                FeedView(apiClient: client)
                    .tabItem { Label("フィード", systemImage: "newspaper") }
            } else {
                ContentUnavailableView(
                    "API 設定を確認してください",
                    systemImage: "exclamationmark.triangle",
                    description: Text("設定タブで API URL とキーを確認してください")
                )
                .tabItem { Label("フィード", systemImage: "newspaper") }
            }
            if let client = appState.apiClient {
                PodcastView(apiClient: client)
                    .tabItem { Label("Podcast", systemImage: "headphones") }
            } else {
                ContentUnavailableView(
                    "API 設定を確認してください",
                    systemImage: "exclamationmark.triangle",
                    description: Text("設定タブで API URL とキーを確認してください")
                )
                .tabItem { Label("Podcast", systemImage: "headphones") }
            }
            // Settings は API 未設定の修正導線として常に表示する。
            // apiClient が nil でも難易度・API 設定は編集可能（RSS 操作のみ無効）。
            SettingsView(apiClient: appState.apiClient)
                .tabItem { Label("設定", systemImage: "gearshape") }
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
