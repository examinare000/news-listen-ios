//
//  PlayerSheetView.swift
//  NewsListenApp
//
//  フルプレイヤーをグローバルシートとして表示する薄いコンテナ。
//  下スワイプ（interactive dismiss）がミニプレイヤーへの最小化に対応する。
//

import SwiftUI

/// フルプレイヤー（`AudioPlayerView`）のシートコンテナ。
///
/// AudioPlayerView 本体には手を入れず、シート表示に必要な修飾だけをここで付ける
/// （view identity 維持の制約は AudioPlayerView 側のコメント参照）。
/// トランスクリプト・語彙の展開で縦に伸びるため ScrollView で包む。
struct PlayerSheetView: View {
    /// 再生状態と操作を提供する ViewModel（ContentView 所有の共有インスタンス）。
    @ObservedObject var vm: PodcastViewModel

    var body: some View {
        ScrollView {
            AudioPlayerView(vm: vm)
        }
        .dsScreenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

#if DEBUG
#Preview("Player Sheet / Light") {
    PlayerSheetView(vm: PreviewSamples.playerViewModel())
}
#endif
