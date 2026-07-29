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
/// RSS ソースの取得/追加/編集/削除は ``SettingsViewModel`` 経由で行う。
struct SettingsView: View {
    /// アプリ全体で共有する設定状態。
    @ObservedObject private var appState: AppState
    /// ADR-088 の端末ローカル設定。サーバー同期せずデバイスごとの好みを尊重する。
    /// キーは DSFeedback で一元管理。
    @AppStorage(DSFeedback.sfxEnabledKey) private var sfxEnabled = true
    @AppStorage(DSFeedback.hapticsEnabledKey) private var hapticsEnabled = true
    /// RSS ソースの取得・追加・編集・削除を担う ViewModel。
    ///
    /// apiClient は `ContentView` から注入し、init で `StateObject` を一度だけ生成する
    /// （`FeedView` と同様、プレースホルダ生成 + 後差し替えのアンチパターンを避ける）。
    @StateObject private var viewModel: SettingsViewModel

    /// RSS ソース追加シートの表示状態。
    @State private var showAddSource = false
    /// 編集シートで開いている編集対象の RSS ソース（`nil` なら非表示・issue #112）。
    @State private var editingSource: RssSource?
    /// キャッシュ全削除の確認ダイアログの表示状態（issue #52）。
    @State private var showClearCacheConfirm = false
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
    @MainActor
    init(appState: AppState) {
        self.appState = appState
        _viewModel = StateObject(wrappedValue: SettingsViewModel(appState: appState))
    }

    var body: some View {
        NavigationStack {
            Form {
                AccountSettingsView(apiClient: appState.apiClient)
                feedSection
                rssSourcesSection
                featuredSitesSection
                generationQuotaSection
                listeningStreakSection
                difficultySection
                playbackSection
                feedbackSection
                cacheSection
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
            .navigationTitle("設定")
            // Settings 画面では聴取ストリークツールバーを表示しない
            // （既存の聴取ストリークセクション内で表示済みのため重複を避ける）
            .sheet(isPresented: $showAddSource) { addSourceSheet }
            .sheet(item: $editingSource) { source in
                EditSourceSheet(source: source, viewModel: viewModel)
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task {
            await viewModel.loadSources()
            await viewModel.loadFeaturedSites()
            await viewModel.loadGenerationQuota()
            await appState.refreshListeningStreak()
            await viewModel.loadCacheSize()
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

            // サーバー設定同期の失敗を可視化する（issue #164）。ローカル値は保持済みのため
            // アラームは出さず、控えめなインライン警告 + 再試行導線にとどめる。
            if appState.preferencesSyncFailed {
                HStack {
                    Text("設定の同期に失敗しました。ローカルの値を表示しています。")
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.danger)
                    Spacer()
                    Button("再試行") { Task { await appState.refreshPreferences() } }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// 購読中一覧の初回読み込み中かどうか。
    ///
    /// 見出しの件数とセクション本体の空状態表示の両方がこの条件で分岐するため、
    /// 二重定義による不整合（見出しは「(0)」なのに本体はスピナー等）を防ぐよう一元化する。
    private var isInitialLoadingSources: Bool {
        viewModel.isLoading && viewModel.sources.isEmpty
    }

    /// 購読中 RSS ソースセクションの見出し。API 利用可能時は購読件数を添える。
    ///
    /// 初回読み込み中は件数が確定していないため「(0)」の誤表示を避けて件数を省略する。
    private var rssSectionTitle: String {
        guard appState.apiClient != nil, !isInitialLoadingSources else { return "購読中のRSSソース" }
        return "購読中のRSSソース (\(viewModel.sources.count))"
    }

    /// 購読中 RSS ソースの一覧（件数・空状態）・編集・削除・追加を行うセクション（issue #112）。
    ///
    /// API クライアントが未設定（URL/キー不正）の場合は操作を提供せず、設定確認を促す。
    /// 行タップの編集シートは admin ロール限定（ADR-047）。一般ユーザーには編集導線を
    /// 表示せず、スワイプ削除（購読解除）と追加のみ提供する。
    @ViewBuilder
    private var rssSourcesSection: some View {
        Section(rssSectionTitle) {
            if appState.apiClient == nil {
                Text("API URL とキーを設定すると RSS ソースを管理できます")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.inkSecondary)
            } else {
                if viewModel.sources.isEmpty {
                    // 初回読み込み中に「ありません」を誤表示しないよう見出しと同じ条件で区別する。
                    if isInitialLoadingSources {
                        ProgressView()
                    } else {
                        Text("購読中のRSSソースはありません")
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.inkSecondary)
                    }
                } else {
                    ForEach(viewModel.sources) { source in
                        if appState.currentUser?.isAdmin == true {
                            Button {
                                editingSource = source
                            } label: {
                                sourceRowLabel(source)
                            }
                            .accessibilityHint("タップすると名称と URL を編集できます")
                        } else {
                            // 既存ソースの編集は admin 特権（ADR-047）。一般ユーザーには
                            // 編集導線そのものを見せない（購読解除のスワイプと追加は残す）。
                            sourceRowLabel(source)
                        }
                    }
                    .onDelete { indexSet in
                        let urls = indexSet.map { viewModel.sources[$0].url }
                        Task {
                            for url in urls { await viewModel.removeSource(url: url) }
                        }
                    }
                }
                Button("ソースを追加") { showAddSource = true }
            }
        }
    }

    /// 購読中ソース行の表示部。編集可否（admin 判定）に依らず共通で使う。
    private func sourceRowLabel(_ source: RssSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name).font(DSFont.headline).foregroundStyle(DSColor.ink)
            Text(source.url).font(DSFont.caption).foregroundStyle(DSColor.inkTertiary)
        }
    }

    /// システム提供のおすすめサイトを一覧し、タップで即購読するセクション。
    ///
    /// API クライアント未設定時は表示しない。取得失敗時（issue #164）はインライン警告 +
    /// 再試行を出すため、`featuredSites` が空でも `featuredSitesLoadFailed` なら表示する。
    @ViewBuilder
    private var featuredSitesSection: some View {
        if appState.apiClient != nil, !viewModel.featuredSites.isEmpty || viewModel.featuredSitesLoadFailed {
            Section("おすすめサイト") {
                ForEach(viewModel.featuredSites) { site in
                    HStack(spacing: 10) {
                        AsyncImage(url: site.thumbnailURL.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "globe").foregroundStyle(DSColor.inkTertiary)
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).font(DSFont.headline).foregroundStyle(DSColor.ink)
                            if let description = site.description {
                                Text(description).font(DSFont.caption).foregroundStyle(DSColor.inkTertiary)
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
                if viewModel.featuredSitesLoadFailed {
                    HStack {
                        Text("おすすめサイトの取得に失敗しました")
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.danger)
                        Spacer()
                        Button("再試行") { Task { await viewModel.loadFeaturedSites() } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// Podcast 生成の本日残回数を表示するセクション（issue #164 / ADR-061）。
    ///
    /// API クライアント未設定時は表示しない。`limit == 0` は無制限を表すため件数は出さない。
    /// 取得失敗時はインライン警告 + 再試行を出す。
    @ViewBuilder
    private var generationQuotaSection: some View {
        if appState.apiClient != nil {
            Section("Podcast 生成") {
                if let quota = viewModel.generationQuota {
                    if quota.limit == 0 {
                        Text("本日の生成回数: 無制限")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.ink)
                    } else {
                        Text("本日の残り生成回数: \(quota.remaining ?? 0) / \(quota.limit)")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.ink)
                    }
                }
                if viewModel.generationQuotaLoadFailed {
                    HStack {
                        Text("生成残回数の取得に失敗しました")
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.danger)
                        Spacer()
                        Button("再試行") { Task { await viewModel.loadGenerationQuota() } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// 聴取ストリーク（連続聴取日数）を表示するセクション（issue #165）。
    ///
    /// API クライアント未設定時は表示しない。「記録なし」の graceful 表示は
    /// `lastListenedDay == nil`（聴取記録が一度もない）で判定する。
    /// `currentStreakDays == 0` は連続記録が途切れているだけの場合もあり、
    /// その場合は最終聴取日を伴う ``ListeningStreak`` としてそのまま表示する
    /// （0日連続 + 過去の最終聴取日、が矛盾なく両立しうるため。issue #165 レビュー指摘）。
    /// 取得失敗時はインライン警告 + 再試行を出す。
    @ViewBuilder
    private var listeningStreakSection: some View {
        if appState.apiClient != nil {
            Section("聴取ストリーク") {
                if let streak = appState.listeningStreak {
                    if let lastListenedDay = streak.lastListenedDay {
                        HStack {
                            DSBadge("\(streak.currentStreakDays)日連続", systemImage: "flame.fill")
                            Spacer()
                            if streak.todayListened {
                                Label("本日聴取済み", systemImage: "checkmark.circle.fill")
                                    .font(DSFont.footnote)
                                    .foregroundStyle(DSColor.success)
                            }
                        }
                        Text("最終聴取日: \(lastListenedDay)")
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.inkSecondary)
                    } else {
                        Text("まだ聴取記録がありません")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.inkSecondary)
                    }
                }
                if appState.listeningStreakLoadFailed {
                    HStack {
                        Text("聴取ストリークの取得に失敗しました")
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.danger)
                        Spacer()
                        Button("再試行") { Task { await appState.refreshListeningStreak() } }
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
            .onChange(of: appState.defaultDifficulty) { oldValue, newValue in
                // ユーザーが難易度を変更したとき、サーバーへ同期する。
                // 失敗時は errorBinding のアラートで通知し、UI 値をサーバー確認済みの
                // 旧値へ戻す（issue #164・無音失敗の解消）。
                Task {
                    let ok = await viewModel.syncDefaultDifficulty(newValue)
                    if !ok { appState.defaultDifficulty = oldValue }
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
            .onChange(of: appState.defaultPlaybackSpeed) { oldValue, newValue in
                // ユーザーが再生速度を変更したとき、サーバーへ同期する。
                // 失敗時は errorBinding のアラートで通知し、UI 値をサーバー確認済みの
                // 旧値へ戻す（issue #164・無音失敗の解消）。
                Task {
                    let ok = await viewModel.syncDefaultPlaybackSpeed(newValue)
                    if !ok { appState.defaultPlaybackSpeed = oldValue }
                }
            }
        }
    }

    /// ADR-088 の効果音・触覚はアカウント設定ではなく端末ローカル設定として保持する。
    private var feedbackSection: some View {
        Section("操作フィードバック") {
            Toggle("効果音", isOn: $sfxEnabled)
                .accessibilityHint("クイズやスワイプ確定時の控えめな効果音を切り替えます")
            Toggle("ハプティクス", isOn: $hapticsEnabled)
                .accessibilityHint("クイズやスワイプ確定時の触覚フィードバックを切り替えます")
        }
    }

    /// ダウンロード音声キャッシュの使用容量表示・全削除セクション（issue #52）。
    ///
    /// LRU 等の自動退避は行わず、手動でのキャッシュ全削除のみ提供する（スコープ外）。
    /// 容量が 0 の間は削除操作を無効化し、無意味な確認ダイアログを出さない。
    private var cacheSection: some View {
        Section("ダウンロード容量") {
            LabeledContent("使用容量", value: formattedCacheSize)
            Button("キャッシュを全削除", role: .destructive) {
                showClearCacheConfirm = true
            }
            .disabled(viewModel.cacheSizeBytes == 0)
        }
        .confirmationDialog(
            "キャッシュを全削除しますか？",
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("全削除", role: .destructive) {
                Task { await viewModel.clearCache() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ダウンロード済みの音声はすべて削除されます。")
        }
    }

    /// バイト数を人間可読な文字列（例: "12.3 MB"）にフォーマットする。
    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: viewModel.cacheSizeBytes, countStyle: .file)
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
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
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

/// 既存 RSS ソースの名称・URL を編集する入力シート（issue #112）。
///
/// `sheet(item:)` から編集対象を受け取り、名称・URL をプリフィルする。
/// 保存・キャンセルの操作はシート自身が担い、完了時に自分で dismiss する
/// （親へ onSave/onCancel クロージャを逆流させない）。保存失敗時のエラーは
/// `SettingsViewModel/errorMessage` 経由で親のアラートに表示される。
private struct EditSourceSheet: View {
    /// シートを閉じるための dismiss アクション。
    @Environment(\.dismiss) private var dismiss

    /// 編集対象の元ソース。更新 API の `oldURL`（対象特定キー）に使う。
    let source: RssSource
    /// 保存処理（`updateSource`）を委譲する ViewModel。親の `SettingsView` が所有する。
    ///
    /// body は `@Published` プロパティを読まない（表示は `source` と自前の `@State` のみ）ため、
    /// 全 publish への購読で無駄な再描画を起こさないようプレーンな参照で保持する。
    let viewModel: SettingsViewModel

    /// 編集中のソース名（元の名称をプリフィル）。
    @State private var name: String
    /// 編集中の RSS URL（元の URL をプリフィル）。
    @State private var url: String

    /// ビューを生成する。
    /// - Parameters:
    ///   - source: 編集対象の RSS ソース。入力欄の初期値になる。
    ///   - viewModel: 保存処理を委譲する ViewModel。
    init(source: RssSource, viewModel: SettingsViewModel) {
        self.source = source
        self.viewModel = viewModel
        _name = State(initialValue: source.name)
        _url = State(initialValue: source.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名前 (例: TechCrunch)", text: $name)
                TextField("RSS URL", text: $url)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
            .navigationTitle("RSS ソースを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await viewModel.updateSource(oldURL: source.url, name: name, url: url)
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}
