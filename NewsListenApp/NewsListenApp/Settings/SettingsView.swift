//
//  SettingsView.swift
//  NewsListenApp
//
//  設定タブのルートビュー。記事の開き方・RSS ソース管理・デフォルト難易度・
//  再生速度・API 設定を扱う。
//

import SwiftUI

/// 設定タブのルートビュー。
///
/// 記事の開き方・RSS ソース管理・デフォルト難易度・再生速度・API 設定を扱う。
/// RSS ソースの取得/追加/削除は ``SettingsViewModel`` 経由で行う。
struct SettingsView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState
    /// RSS ソースの取得・追加・削除を担う ViewModel。
    ///
    /// apiClient は `ContentView` から注入し、init で `StateObject` を一度だけ生成する
    /// （`FeedView` と同様、プレースホルダ生成 + 後差し替えのアンチパターンを避ける）。
    @StateObject private var viewModel: SettingsViewModel

    /// RSS ソース追加シートの表示状態。
    @State private var showAddSource = false
    /// 追加シートで入力中のソース名。
    @State private var newSourceName = ""
    /// 追加シートで入力中の RSS URL。
    @State private var newSourceURL = ""

    /// 設定画面で選択できる難易度の一覧（値, 表示ラベル）。
    private let difficulties: [(String, String)] = [
        ("toeic_600", "TOEIC 600以下"),
        ("toeic_900", "TOEIC 730〜900"),
        ("ielts_55", "IELTS 5.5〜6.5"),
        ("ielts_7", "IELTS 7.0以上"),
        ("eiken_2", "英検2級"),
        ("eiken_p1", "英検準1級以上"),
    ]

    /// 設定画面で選択できる再生速度の候補。
    private let playbackSpeeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// ビューを生成する。
    /// - Parameter apiClient: ViewModel に注入する API クライアント。未設定時は `nil`。
    init(apiClient: APIClient?) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            Form {
                AccountSettingsView(apiClient: appState.apiClient)
                feedSection
                rssSourcesSection
                featuredSitesSection
                difficultySection
                playbackSection
            }
            .navigationTitle("設定")
            .sheet(isPresented: $showAddSource) { addSourceSheet }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task {
            await viewModel.loadSources()
            await viewModel.loadFeaturedSites()
        }
    }

    /// 記事の開き方（アプリ内 / 外部 Safari）を切り替えるセクション。
    private var feedSection: some View {
        Section("フィード") {
            Picker("記事の開き方", selection: $appState.articleOpenMode) {
                ForEach(ArticleOpenMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .accessibilityHint("記事を現在のアプリ内 Safari で開くか、システムの Safari で開くかを選択できます")
            Picker("記事の日付表記", selection: $appState.timeFormat) {
                Text("絶対表記 (YYYY-MM-DD)").tag("absolute")
                Text("相対表記 (N分前)").tag("relative")
            }
            .accessibilityHint("記事の公開日を絶対表記 (YYYY-MM-DD) または相対表記 (N分前など) で表示するか選択できます")
        }
    }

    /// RSS ソースの一覧・削除・追加を行うセクション。
    ///
    /// API クライアントが未設定（URL/キー不正）の場合は操作を提供せず、設定確認を促す。
    @ViewBuilder
    private var rssSourcesSection: some View {
        Section("RSS ソース") {
            if appState.apiClient == nil {
                Text("API URL とキーを設定すると RSS ソースを管理できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.sources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).font(.headline)
                        Text(source.url).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { indexSet in
                    let urls = indexSet.map { viewModel.sources[$0].url }
                    Task {
                        for url in urls { await viewModel.removeSource(url: url) }
                    }
                }
                Button("ソースを追加") { showAddSource = true }
            }
        }
    }

    /// システム提供のおすすめサイトを一覧し、タップで即購読するセクション。
    ///
    /// API クライアント未設定時、またはおすすめサイトが空の場合は表示しない。
    @ViewBuilder
    private var featuredSitesSection: some View {
        if appState.apiClient != nil, !viewModel.featuredSites.isEmpty {
            Section("おすすめサイト") {
                ForEach(viewModel.featuredSites) { site in
                    HStack(spacing: 10) {
                        AsyncImage(url: site.thumbnailURL.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).font(.headline)
                            if let description = site.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        // ワンクリックで即購読（既存 addSource を再利用）。
                        Button("購読") {
                            Task { await viewModel.addSource(name: site.name, url: site.url) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// デフォルト難易度を選択するセクション。
    private var difficultySection: some View {
        Section("デフォルト難易度") {
            Picker("難易度", selection: $appState.defaultDifficulty) {
                ForEach(difficulties, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
        }
    }

    /// 既定の再生速度を選択するセクション。
    private var playbackSection: some View {
        Section("再生速度") {
            Picker("デフォルト再生速度", selection: $appState.defaultPlaybackSpeed) {
                ForEach(playbackSpeeds, id: \.self) { speed in
                    Text(String(format: "%g×", speed)).tag(speed)
                }
            }
        }
    }

    /// RSS ソースを追加する入力シート。
    private var addSourceSheet: some View {
        NavigationStack {
            Form {
                TextField("名前 (例: TechCrunch)", text: $newSourceName)
                TextField("RSS URL", text: $newSourceURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            .navigationTitle("RSS ソースを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismissAddSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        Task {
                            await viewModel.addSource(name: newSourceName, url: newSourceURL)
                            dismissAddSheet()
                        }
                    }
                    .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)
                }
            }
        }
    }

    /// 追加シートを閉じ、入力欄をクリアする。
    private func dismissAddSheet() {
        newSourceName = ""
        newSourceURL = ""
        showAddSource = false
    }

    /// エラーアラートの表示有無を `errorMessage` の有無に橋渡しする `Binding`。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
