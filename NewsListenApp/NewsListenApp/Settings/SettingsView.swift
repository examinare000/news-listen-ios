//
//  SettingsView.swift
//  NewsListenApp
//
//  設定タブ。現状は「記事の開き方」のみ実装。難易度・再生速度・RSS ソース管理・
//  API 設定・テーマ切替は Task 7 で追加する。
//

import SwiftUI

/// 設定タブ。
///
/// 現状は「記事の開き方」のみ実装。難易度・再生速度・RSS ソース管理・API 設定・
/// テーマ切替は Task 7 で追加する。
struct SettingsView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            Form {
                Section("フィード") {
                    Picker("記事の開き方", selection: $appState.articleOpenMode) {
                        ForEach(ArticleOpenMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section {
                    // Task 7 で難易度・再生速度・RSS ソース・API 設定・テーマを追加予定。
                    Text("その他の設定は今後追加されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
        }
    }
}
