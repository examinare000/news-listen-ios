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

    /// 速度切替 Picker に並べる選択肢（倍率）。ロック画面/CC と共有する単一の真実。
    private let speeds: [Float] = PlaybackConstants.speeds

    /// トランスクリプト折りたたみの開閉状態。
    /// WHY: 新規詳細画面を作らずこのプレイヤー内で完結させる（issue #162 のユーザー決定）ため、
    ///      ナビゲーションではなく View ローカルの開閉状態として保持する。
    @State private var isTranscriptExpanded = false

    var body: some View {
        VStack(spacing: DSSpacing.l) {
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
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.m) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
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
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("話者\(segment.speaker): \(segment.text)")
                    }
                }
                .padding(.top, DSSpacing.s)
            }
            // WHY: 発話数が多い場合でもプレイヤー全体の高さを一定に保ち、
            //      シークバーや再生ボタンの位置がずれないようにする。
            .frame(maxHeight: 200)
        } label: {
            Text("トランスクリプト")
                .font(DSFont.meta)
                .foregroundStyle(DSColor.inkSecondary)
        }
        .tint(DSColor.accent)
        .accessibilityHint(isTranscriptExpanded ? "トランスクリプトを折りたたみます" : "トランスクリプトを展開して表示します")
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
#endif
