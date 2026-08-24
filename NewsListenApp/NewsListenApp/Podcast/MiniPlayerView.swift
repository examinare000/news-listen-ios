//
//  MiniPlayerView.swift
//  NewsListenApp
//
//  全タブ共通の下部ミニプレイヤー。再生中タイトルと再生/一時停止のみの
//  最小 UI で、タップでフルプレイヤーシートを開く。
//

import SwiftUI

/// 全タブ共通の下部ミニプレイヤー。
///
/// タブバー直上に `.safeAreaInset` で差し込まれる前提の水平バー。
/// 詳細操作（シーク・速度・トランスクリプト等）はフルプレイヤーに委ね、
/// ここでは「何が流れているか」と再生/一時停止だけを提供する。
struct MiniPlayerView: View {
    /// 再生状態と操作を提供する ViewModel（ContentView 所有の共有インスタンス）。
    @ObservedObject var vm: PodcastViewModel

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            HStack(spacing: DSSpacing.m) {
                Text(vm.currentPodcast?.displayTitle ?? "")
                    .font(DSFont.meta)
                    .foregroundStyle(DSColor.ink)
                    .lineLimit(1)
                Spacer(minLength: DSSpacing.s)
                controlButton
            }
            .padding(.horizontal, DSSpacing.l)
            .padding(.vertical, DSSpacing.m)
        }
        .background(DSColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DSColor.hairline)
                .frame(height: 1)
        }
        // バー全体をタップ対象にする（Button 部分は Button が優先される）。
        .contentShape(Rectangle())
        .onTapGesture { vm.expandPlayer() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("再生中: \(vm.currentPodcast?.displayTitle ?? "")")
        .accessibilityHint("タップでプレイヤーを開きます")
    }

    /// 上端の極細再生プログレス。シーク操作はフルプレイヤーに委ねる表示専用バー。
    private var progressBar: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(DSColor.accent)
                .frame(width: proxy.size.width * progressFraction)
        }
        .frame(height: 2)
        .background(DSColor.accentSoft)
        .accessibilityHidden(true)
    }

    /// 再生状態に応じた単一の操作ボタン（バッファ中はスピナー）。
    @ViewBuilder
    private var controlButton: some View {
        if vm.isBuffering {
            ProgressView()
        } else if vm.didFinishCurrentEpisode {
            Button {
                Task { await vm.replayCurrentEpisode() }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
                    .foregroundStyle(DSColor.accent)
            }
            .accessibilityLabel("もう一度聴く")
        } else {
            Button {
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(DSColor.accent)
            }
            .accessibilityLabel(vm.isPlaying ? "一時停止" : "再生")
        }
    }

    /// 0...1 の再生進捗。duration 未確定（0）の間は 0 を返す。
    private var progressFraction: CGFloat {
        guard vm.duration > 0 else { return 0 }
        return CGFloat(min(max(vm.currentTime / vm.duration, 0), 1))
    }
}

/// `withMiniPlayer` の差し込み内容。
/// WHY: `safeAreaInset` のクロージャ内で直接 `vm.presentation` を分岐すると、呼び出し元
///      View が VM を購読していない場合に表示切替が再評価されない。購読する View として
///      切り出すことで、presentation の変化が確実に反映される。
private struct MiniPlayerInset: View {
    @ObservedObject var vm: PodcastViewModel

    var body: some View {
        if vm.presentation == .mini {
            MiniPlayerView(vm: vm)
        }
    }
}

extension View {
    /// タブの root にミニプレイヤーを差し込む。`presentation == .mini` のときだけ表示され、
    /// `safeAreaInset` によりスクロール内容は自動でバーの高さ分インセットされる。
    func withMiniPlayer(_ vm: PodcastViewModel) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerInset(vm: vm)
        }
    }
}

#if DEBUG
#Preview("Mini Player / Light") {
    MiniPlayerView(vm: PreviewSamples.playerViewModel())
}

#Preview("Mini Player / Dark") {
    MiniPlayerView(vm: PreviewSamples.playerViewModel())
        .preferredColorScheme(.dark)
}
#endif
