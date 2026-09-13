//
//  AudioPlayerView.swift
//  NewsListenApp
//
//  再生中の Podcast を操作するプレイヤー UI。日本語イントロ・シークバー・
//  再生コントロール・再生速度切替を表示する。
//

import SwiftUI

/// 再生中の Podcast を操作するプレイヤー UI。
///
/// 日本語イントロ・シークバー・再生コントロール・再生速度切替を表示する。
struct AudioPlayerView: View {
    /// 再生状態と操作を提供する ViewModel。
    @ObservedObject var vm: PodcastViewModel

    /// トランスクリプト同期のタイミング供給源。既定は文字数按分の推定
    /// （バックエンドが実時刻を返すようになったらここを差し替える）。
    var transcriptTiming: TranscriptTimingProviding = EstimatedTranscriptTiming()

    /// 速度切替 Picker に並べる選択肢（倍率）。ロック画面/CC と共有する単一の真実。
    private let speeds: [Float] = PlaybackConstants.speeds

    /// トランスクリプト折りたたみの開閉状態。
    /// WHY: 新規詳細画面を作らずこのプレイヤー内で完結させる（issue #162 のユーザー決定）ため、
    ///      ナビゲーションではなく View ローカルの開閉状態として保持する。
    @State private var isTranscriptExpanded = false
    /// 各セグメントの推定開始秒（エピソード切替時に再計算）。nil なら同期機能を無効化。
    @State private var segmentOffsets: [Double]?
    /// 再生位置に対応するアクティブセグメント index。イントロ区間・未算出時は nil。
    @State private var activeTranscriptIndex: Int?
    /// 手動スクロール中は自動追従を止める（約3秒の無操作で復帰）。
    @State private var isUserScrollingTranscript = false
    /// 自動追従復帰のデバウンス Task。
    @State private var transcriptResumeTask: Task<Void, Never>?
    /// 語彙グロッサリの開閉状態。
    @State private var isVocabularyExpanded = false
    /// クイズ導線タップ時の Podcast スナップショット。
    @State private var quizPodcast: Podcast?
    /// 現在の Podcast で個人語彙帳へ登録済みの正規化語。
    @State private var registeredTerms: Set<String> = []
    /// 保存リクエスト中の語。連打を抑止し冪等 API への不要な重複送信を避ける。
    @State private var savingTerms: Set<String> = []
    @State private var vocabularySaveError: String?

    /// 語彙リストの最大高さ（Dynamic Type に応じてスケール）。
    @ScaledMetric(relativeTo: .body) private var vocabularyListMaxHeight: CGFloat = 200

    var body: some View {
        // WHY: view identity（this VStack）を維持したまま内側で分岐する。差し替え方式だと
        //      .sheet(item:) / .task(id:) / .alert が乗る修飾子ごと入れ替わり、完了の瞬間に
        //      表示中のクイズシートが強制 dismiss される（AudioPlayerView 自体は差し替えない）。
        VStack(spacing: DSSpacing.l) {
            if vm.didFinishCurrentEpisode {
                finishedContent
            } else {
                playingContent
            }
        }
        .padding(.vertical, DSSpacing.l)
        .frame(maxWidth: .infinity)
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(DSColor.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: -2)
        .padding(DSSpacing.l)
        .sheet(item: $quizPodcast) { podcast in
            QuizSheetView(podcast: podcast) { answers in
                try await vm.submitQuizAnswers(podcastId: podcast.id, answers: answers)
            }
        }
        .task(id: vm.currentPodcast?.id) {
            guard let podcast = vm.currentPodcast else { return }
            registeredTerms = []
            // エピソード切替でトランスクリプト同期状態を再構築する。
            // WHY: キュー自動遷移は expandsPlayer: false で本 View を生かしたまま次エピソードへ
            //      移るため、手動スクロール中の一時停止状態を持ち越すと新エピソードの自動追従が
            //      最大3秒抑止される。追従状態も併せてリセットする。
            resetTranscriptAutoScrollPause()
            segmentOffsets = transcriptTiming.segmentStartOffsets(for: podcast)
            activeTranscriptIndex = nil
            await loadSavedVocabulary(for: podcast)
        }
        .onDisappear {
            // View が階層から外れたら復帰待ちの Task を残さない。
            resetTranscriptAutoScrollPause()
        }
        .onChange(of: vm.currentTime) { _, time in
            // periodicTimeObserver（0.5秒毎）駆動。index が変わったときだけ書き込み、
            // ハイライト・自動スクロールの不要な再評価を避ける。
            guard let offsets = segmentOffsets else { return }
            let newIndex = EstimatedTranscriptTiming.activeSegmentIndex(offsets: offsets, currentTime: time)
            if newIndex != activeTranscriptIndex {
                activeTranscriptIndex = newIndex
            }
        }
        .alert("語彙の登録に失敗しました", isPresented: vocabularySaveErrorBinding) {
            Button("OK") { vocabularySaveError = nil }
        } message: {
            Text(vocabularySaveError ?? "")
        }
        .onChange(of: vm.didFinishCurrentEpisode) { _, finished in
            // WHY: finished/playing 双方向の遷移でリセットする。
            //      finished→playing（replay）時に展開状態を持ち越さないため。
            //      VoiceOver通知は finished=true 遷移時のみ（レイアウト確定後の読み上げが必要）。
            isTranscriptExpanded = false
            isVocabularyExpanded = false
            if finished {
                UIAccessibility.post(notification: .layoutChanged, argument: nil)
            }
        }
    }

    /// フルプレイヤー表示（再生中/一時停止中）。
    @ViewBuilder
    private var playingContent: some View {
        // 再生中ラベル＋日本語イントロ（セリフで雑誌的に）
        VStack(spacing: DSSpacing.s) {
            Text("再生中")
                .dsEyebrow()
            if let podcast = vm.currentPodcast, !podcast.japaneseIntroText.isEmpty {
                Text(podcast.japaneseIntroText)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal)

        // トランスクリプト（折りたたみ）
        // WHY: segments が無い（旧エピソード・未デプロイ環境）場合は何も描画しない
        //      グレースフルデグレードにより、レイアウトを不変に保つ（issue #162）。
        if let podcast = vm.currentPodcast, podcast.hasTranscript {
            transcriptSection(segments: podcast.segments ?? [])
                .padding(.horizontal)
        }

        if let podcast = vm.currentPodcast, podcast.hasVocabulary || podcast.hasQuiz {
            learningSections(podcast)
                .padding(.horizontal)
        }

        // シークバー
        VStack(spacing: DSSpacing.xs) {
            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(vm.duration, 1)
            )
            .tint(DSColor.accent)
            HStack {
                Text(formatTime(vm.currentTime))
                Spacer()
                Text(formatTime(vm.duration))
            }
            .font(DSFont.caption.monospacedDigit())
            .foregroundStyle(DSColor.inkSecondary)
        }
        .padding(.horizontal)

        // バッファリング中インジケータ（issue #51）。
        // WHY: 再生ボタンの見た目は isPlaying のまま変わらないため、無反応に見える stall 状態を
        //      利用者に伝える最小限の表示として、コントロール直上にラベル付きスピナーを出す。
        if vm.isBuffering {
            HStack(spacing: DSSpacing.xs) {
                ProgressView()
                    .scaleEffect(0.8, anchor: .center)
                Text("バッファリング中…")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("バッファリング中")
        }

        // 再生コントロール
        HStack(spacing: DSSpacing.xxl + DSSpacing.s) {
            Button {
                vm.seek(to: max(0, vm.currentTime - PlaybackConstants.skipBackwardSeconds))
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .foregroundStyle(DSColor.ink)
            }
            .accessibilityLabel("15秒戻す")
            .accessibilityHint("再生位置を15秒前に移動します")

            Button {
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(DSColor.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(vm.isPlaying ? "一時停止" : "再生")
            .accessibilityHint(vm.isPlaying ? "再生を一時停止します" : "再生を開始します")

            Button {
                vm.seek(to: min(vm.duration, vm.currentTime + PlaybackConstants.skipForwardSeconds))
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .foregroundStyle(DSColor.ink)
            }
            .accessibilityLabel("30秒進む")
            .accessibilityHint("再生位置を30秒先に移動します")
        }

        // 再生速度
        Picker("速度", selection: Binding(
            get: { vm.playbackSpeed },
            set: { vm.setSpeed($0) }
        )) {
            ForEach(speeds, id: \.self) { speed in
                Text(speedLabel(speed)).tag(speed)
            }
        }
        .pickerStyle(.segmented)
        .tint(DSColor.accent)
        .padding(.horizontal)

        // 出典・ライセンス表示（ADR-095 / issue #240）。
        // WHY: プレイヤー操作（シークバー・再生ボタン）の位置を押し下げないよう末尾に置く。
        if let podcast = vm.currentPodcast, podcast.hasSourceArticles {
            attributionSection(podcast)
                .padding(.horizontal)
        }
    }

    /// 聴き終わり後のコンパクト表示。シークバー・再生コントロール・トランスクリプトは出さず、
    /// 「もう一度聴く」と語彙/クイズ導線を残す。出典・ライセンス表記は帰属要件のため
    /// 再生状態によらず両状態で末尾に出す（issue #240）。
    @ViewBuilder
    private var finishedContent: some View {
        VStack(spacing: DSSpacing.s) {
            Text("聴き終わりました")
                .dsEyebrow()
            if let podcast = vm.currentPodcast, !podcast.japaneseIntroText.isEmpty {
                Text(podcast.japaneseIntroText)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)

        if let podcast = vm.currentPodcast, podcast.hasVocabulary || podcast.hasQuiz {
            learningSections(podcast)
                .padding(.horizontal)
        }

        Button {
            Task { await vm.replayCurrentEpisode() }
        } label: {
            Label("もう一度聴く", systemImage: "arrow.counterclockwise")
                .font(DSFont.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(DSColor.accent)
        .padding(.horizontal)
        .accessibilityLabel("もう一度聴く")
        .accessibilityHint("このエピソードを先頭から再生します")

        // 出典・ライセンス表示（ADR-095 / issue #240）。
        if let podcast = vm.currentPodcast, podcast.hasSourceArticles {
            attributionSection(podcast)
                .padding(.horizontal)
        }
    }

    /// 秒数を `分:秒`（例: `1:05`）の表示用文字列へ整形する。非有限値は `0:00` を返す。
    /// - Parameter seconds: 整形する秒数。
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// 再生速度を表示用ラベルへ整形する。
    ///
    /// 整数倍速は `×1.0`、それ以外は `×0.75` のように表示桁を出し分ける。
    /// - Parameter speed: 再生速度（倍率）。
    private func speedLabel(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return String(format: "×%.1f", speed)
        }
        return String(format: "×%.2f", speed)
    }

    /// 文字起こしの折りたたみ表示セクション。
    ///
    /// 展開時は `ScrollView` で高さを有界にし、プレイヤー本体の操作（シーク・再生ボタン等）を
    /// 押し下げないようにする。
    /// - Parameter segments: 表示する発話一覧（非空であることを呼び出し側が保証する）。
    @ViewBuilder
    private func transcriptSection(segments: [TranscriptSegment]) -> some View {
        DisclosureGroup(isExpanded: $isTranscriptExpanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.m) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            transcriptRow(index: index, segment: segment)
                        }
                    }
                    .padding(.top, DSSpacing.s)
                }
                // WHY: 発話数が多い場合でもプレイヤー全体の高さを一定に保ち、
                //      シークバーや再生ボタンの位置がずれないようにする。
                .frame(maxHeight: 200)
                // WHY: iOS 17 デプロイターゲットでは .onScrollPhaseChange が使えないため、
                //      ドラッグ検知で手動スクロールとみなし自動追従を一時停止する。
                .simultaneousGesture(
                    DragGesture().onChanged { _ in pauseTranscriptAutoScroll() }
                )
                .onChange(of: activeTranscriptIndex) { _, newIndex in
                    guard isTranscriptExpanded, !isUserScrollingTranscript, let newIndex else { return }
                    withAnimation(.easeInOut) { proxy.scrollTo(newIndex, anchor: .center) }
                }
                .onChange(of: isTranscriptExpanded) { _, expanded in
                    // 展開した瞬間は現在の再生位置へアニメーションなしでジャンプする。
                    guard expanded, let index = activeTranscriptIndex else { return }
                    proxy.scrollTo(index, anchor: .center)
                }
                .onChange(of: isUserScrollingTranscript) { _, scrolling in
                    // 手動スクロールからの復帰時、次のセグメント切替を待たずに追従へ戻す。
                    guard !scrolling, isTranscriptExpanded, let index = activeTranscriptIndex else { return }
                    withAnimation(.easeInOut) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        } label: {
            Text("トランスクリプト")
                .font(DSFont.meta)
                .foregroundStyle(DSColor.inkSecondary)
        }
        .tint(DSColor.accent)
        .accessibilityHint(isTranscriptExpanded ? "トランスクリプトを折りたたみます" : "トランスクリプトを展開して表示します")
    }

    /// トランスクリプトの1発話行。再生中の行はハイライトし、タップで推定位置へシークする。
    @ViewBuilder
    private func transcriptRow(index: Int, segment: TranscriptSegment) -> some View {
        let isActive = index == activeTranscriptIndex
        HStack(alignment: .top, spacing: DSSpacing.s) {
            Text(segment.speaker)
                .font(DSFont.caption.weight(.semibold))
                .foregroundStyle(DSColor.accent)
                .frame(minWidth: 20, alignment: .leading)
            Text(segment.text)
                .font(DSFont.body)
                .foregroundStyle(DSColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DSSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                .fill(isActive ? DSColor.accentSoft : Color.clear)
        )
        .id(index)
        .contentShape(Rectangle())
        .onTapGesture {
            // 推定オフセットへのシーク。推定誤差をユーザー自身が補正する手段も兼ねる。
            guard let offsets = segmentOffsets, offsets.indices.contains(index) else { return }
            vm.seek(to: offsets[index])
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("話者\(segment.speaker): \(segment.text)")
        .accessibilityHint("タップでこの発話の推定位置へ移動します")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// 手動スクロールとみなして自動追従を止め、約3秒の無操作で復帰させる。
    private func pauseTranscriptAutoScroll() {
        isUserScrollingTranscript = true
        transcriptResumeTask?.cancel()
        transcriptResumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            isUserScrollingTranscript = false
        }
    }

    /// 自動追従の一時停止を即座に解除し、復帰待ちの Task を破棄する。
    private func resetTranscriptAutoScrollPause() {
        transcriptResumeTask?.cancel()
        transcriptResumeTask = nil
        isUserScrollingTranscript = false
    }

    /// 語彙グロッサリと理解度クイズへの導線を近接配置する。
    @ViewBuilder
    private func learningSections(_ podcast: Podcast) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.m) {
            if podcast.hasVocabulary {
                vocabularySection(entries: podcast.vocabulary ?? [])
            }
            if podcast.hasQuiz {
                Button {
                    quizPodcast = podcast
                } label: {
                    Label("聴き終わったら試す", systemImage: "questionmark.bubble")
                        .font(DSFont.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(DSColor.accent)
                .accessibilityLabel("聴き終わったら試す")
                .accessibilityHint("このエピソードの\(podcast.quiz?.count ?? 0)問クイズを開きます")
            }
        }
    }

    /// 語彙グロッサリの折りたたみ表示。長い場合もプレイヤー操作を押し下げない。
    @ViewBuilder
    private func vocabularySection(entries: [VocabularyEntry]) -> some View {
        DisclosureGroup(isExpanded: $isVocabularyExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.m) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        let key = normalizedTerm(entry.term)
                        let isRegistered = registeredTerms.contains(key)
                        let isSaving = savingTerms.contains(key)
                        let buttonText = isSaving ? "登録中" : (isRegistered ? "登録済み" : "習得")
                        HStack(alignment: .top, spacing: DSSpacing.m) {
                            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                Text(entry.term)
                                    .font(DSFont.headline)
                                    .foregroundStyle(DSColor.ink)
                                Text(entry.meaningJa)
                                    .font(DSFont.body)
                                    .foregroundStyle(DSColor.ink)
                                Text(entry.example)
                                    .font(DSFont.meta.italic())
                                    .foregroundStyle(DSColor.inkSecondary)
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: DSSpacing.s)
                            Button(buttonText) {
                                guard let podcast = vm.currentPodcast else { return }
                                Task { await save(entry, for: podcast) }
                            }
                            .buttonStyle(.bordered)
                            .tint(isRegistered || isSaving ? DSColor.inkSecondary : DSColor.accent)
                            .opacity((isRegistered || isSaving) ? 0.45 : 1)
                            .disabled(isRegistered || isSaving)
                            .accessibilityLabel(
                                isSaving ? "\(entry.term)を登録中" : (isRegistered ? "\(entry.term)は登録済み" : "\(entry.term)を習得語彙に登録")
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, DSSpacing.s)
            }
            .frame(maxHeight: vocabularyListMaxHeight)
        } label: {
            Label("語彙グロッサリ", systemImage: "text.book.closed")
                .font(DSFont.meta)
                .foregroundStyle(DSColor.inkSecondary)
        }
        .tint(DSColor.accent)
        .accessibilityHint(isVocabularyExpanded ? "語彙グロッサリを折りたたみます" : "語彙グロッサリを展開して表示します")
    }

    private func normalizedTerm(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 出典（ソース名・記事タイトル・原文リンク）と、`featured` のときだけの CC BY-SA 4.0 表示。
    /// web `page.tsx` と同一文言・同一構造（ADR-095 / issue #240）。
    /// - Parameter podcast: `hasSourceArticles == true` であることを呼び出し側が保証する。
    @ViewBuilder
    private func attributionSection(_ podcast: Podcast) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("出典")
                .dsEyebrow()
                .accessibilityAddTraits(.isHeader)
            ForEach(Array((podcast.sourceArticles ?? []).enumerated()), id: \.offset) { _, article in
                HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
                    Text(article.source)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.inkSecondary)
                    Text("·")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.inkTertiary)
                    if let url = article.linkURL {
                        Link(article.title, destination: url)
                            .font(DSFont.caption)
                            .tint(DSColor.accent)
                            .lineLimit(2)
                            .accessibilityHint("原文を外部ブラウザで開きます")
                    } else {
                        // WHY: url が非 http(s) / 不正な要素は openURL に渡さず、帰属表示だけは維持する。
                        Text(article.title)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.ink)
                            .lineLimit(2)
                    }
                }
            }
            if podcast.showsCcBySaLicense {
                // WHY: 「featured かつ出典なし」ではこのブロック自体が描画されない
                //      （呼び出し元の hasSourceArticles ガード）ため、ライセンス文だけの単独表示は起きない。
                Text(Podcast.ccBySaLicenseNotice)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.inkSecondary)
                    .tint(DSColor.accent)
                    .padding(.top, DSSpacing.xs)
            }
        }
    }

    /// 初期状態は best-effort。旧 server やオフライン時もプレイヤーをエラーにしない。
    private func loadSavedVocabulary(for podcast: Podcast) async {
        guard let response = try? await vm.fetchSavedVocabulary() else { return }
        guard !Task.isCancelled, vm.currentPodcast?.id == podcast.id else { return }
        registeredTerms = Set(
            response.vocabulary
                .filter { $0.podcastId == podcast.id }
                .map { normalizedTerm($0.term) }
        )
    }

    private func save(_ entry: VocabularyEntry, for podcast: Podcast) async {
        let key = normalizedTerm(entry.term)
        guard !registeredTerms.contains(key), !savingTerms.contains(key) else { return }
        savingTerms.insert(key)
        defer { savingTerms.remove(key) }
        do {
            _ = try await vm.saveVocabulary(podcastId: podcast.id, term: entry.term)
            if vm.currentPodcast?.id == podcast.id {
                registeredTerms.insert(key)
            }
        } catch {
            vocabularySaveError = "通信状況を確認して、もう一度お試しください。"
        }
    }

    private var vocabularySaveErrorBinding: Binding<Bool> {
        Binding(
            get: { vocabularySaveError != nil },
            set: { if !$0 { vocabularySaveError = nil } }
        )
    }
}

#if DEBUG
#Preview("Player / Light") {
    VStack {
        Spacer()
        AudioPlayerView(vm: PreviewSamples.playerViewModel())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DSColor.paper)
}

#Preview("Player / Dark") {
    VStack {
        Spacer()
        AudioPlayerView(vm: PreviewSamples.playerViewModel())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DSColor.paper)
    .preferredColorScheme(.dark)
}

#Preview("Player / Finished") {
    VStack {
        Spacer()
        AudioPlayerView(vm: PreviewSamples.finishedPlayerViewModel())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DSColor.paper)
}
#endif
