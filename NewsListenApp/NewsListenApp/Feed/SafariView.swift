//
//  SafariView.swift
//  NewsListenApp
//
//  SFSafariViewController を SwiftUI から使うためのラッパー。
//  記事をアプリ内 Safari で開く（要件 AC-5・設計 §7）。
//

import SwiftUI
import SafariServices

/// `SFSafariViewController` を SwiftUI から使うためのラッパー。
///
/// 記事をアプリ内 Safari で開く（要件 AC-5・設計 §7）。
struct SafariView: UIViewControllerRepresentable {
    /// 表示する記事の URL。
    let url: URL

    /// 指定 URL で `SFSafariViewController` を生成する。
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    /// SwiftUI の再構成時に呼ばれるが、本ビューでは更新不要。
    ///
    /// 再構成で URL は変えない（毎回新しい sheet を提示する設計のため）。
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
    }
}
