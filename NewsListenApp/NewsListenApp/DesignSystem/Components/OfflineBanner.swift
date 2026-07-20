//
//  OfflineBanner.swift
//  NewsListenApp
//
//  オフライン時に画面上部へ表示する共有バナー（issue #54）。
//  Feed / Podcast 両画面で、ネットワーク断を事前に知らせるために使う。
//

import SwiftUI

/// オフライン時に画面上部へ表示する帯状バナー。
///
/// 呼び出し側は `if !viewModel.isOnline { OfflineBanner() }` のように条件表示する。
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: DSSpacing.s) {
            Image(systemName: "wifi.slash")
            Text("オフラインです")
        }
        .font(DSFont.caption.weight(.semibold))
        .foregroundStyle(DSColor.onAccent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.s)
        .background(DSColor.danger)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("オフラインです")
    }
}

#if DEBUG
#Preview("OfflineBanner / Light") { OfflineBanner() }
#Preview("OfflineBanner / Dark") { OfflineBanner().preferredColorScheme(.dark) }
#endif
