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

    var body: some View {
        VStack(spacing: 16) {
            // 日本語イントロ表示
            if let podcast = vm.currentPodcast, !podcast.japaneseIntroText.isEmpty {
                Text(podcast.japaneseIntroText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            // シークバー
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { vm.currentTime },
                        set: { vm.seek(to: $0) }
                    ),
                    in: 0...max(vm.duration, 1)
                )
                HStack {
                    Text(formatTime(vm.currentTime))
                    Spacer()
                    Text(formatTime(vm.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // 再生コントロール
            HStack(spacing: 40) {
                Button {
                    vm.seek(to: max(0, vm.currentTime - PlaybackConstants.skipBackwardSeconds))
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .accessibilityLabel("15秒戻す")
                .accessibilityHint("再生位置を15秒前に移動します")

                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(.largeTitle))
                }
                .accessibilityLabel(vm.isPlaying ? "一時停止" : "再生")
                .accessibilityHint(vm.isPlaying ? "再生を一時停止します" : "再生を開始します")

                Button {
                    vm.seek(to: min(vm.duration, vm.currentTime + PlaybackConstants.skipForwardSeconds))
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title2)
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
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding()
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
}
