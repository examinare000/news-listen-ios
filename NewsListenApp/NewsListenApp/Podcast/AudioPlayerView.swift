//
//  AudioPlayerView.swift
//  NewsListenApp
//
//  再生中の Podcast を操作するプレイヤー UI。日本語イントロ・シークバー・
//  再生コントロール・再生速度切替を表示する。
//

import SwiftUI

struct AudioPlayerView: View {
    @ObservedObject var vm: PodcastViewModel

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5]

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
                    vm.seek(to: max(0, vm.currentTime - 15))
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }

                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }

                Button {
                    vm.seek(to: min(vm.duration, vm.currentTime + 30))
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title2)
                }
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // 整数倍速は ×1.0、それ以外は ×0.75 のように表示桁を出し分ける。
    private func speedLabel(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return String(format: "×%.1f", speed)
        }
        return String(format: "×%.2f", speed)
    }
}
