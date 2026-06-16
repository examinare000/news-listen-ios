//
//  NewsListenAppApp.swift
//  NewsListenApp
//
//  @main エントリポイント。AppState が未設定なら初期設定画面、設定済みなら
//  タブビュー（フィード / Podcast / 設定）を表示する。
//

import SwiftUI

@main
struct NewsListenAppApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            if appState.isConfigured {
                ContentView()
                    .environmentObject(appState)
            } else {
                InitialSetupView()
                    .environmentObject(appState)
            }
        }
    }
}

// 初回設定画面（API URL と API キーを入力）
struct InitialSetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var urlInput = ""
    @State private var keyInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("API 設定") {
                    TextField("API URL (例: https://podcast-api-xxx.run.app)", text: $urlInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API キー", text: $keyInput)
                }
                Button("設定を保存") {
                    appState.apiBaseURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.apiKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .disabled(!canSave)
            }
            .navigationTitle("初期設定")
            // 既存値・ビルド注入値があればフィールドへ反映し、保存ボタンを活性化する。
            // （通常は注入済みなら本画面はスキップされるが、未注入時の手動入力に備える）
            .onAppear {
                if urlInput.isEmpty { urlInput = appState.apiBaseURL }
                if keyInput.isEmpty { keyInput = appState.apiKey }
            }
        }
    }

    private var canSave: Bool {
        !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// メインタブビュー
struct ContentView: View {
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
            PodcastView()
                .tabItem { Label("Podcast", systemImage: "headphones") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}
