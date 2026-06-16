//
//  SafariView.swift
//  NewsListenApp
//
//  SFSafariViewController を SwiftUI から使うためのラッパー。
//  記事をアプリ内 Safari で開く（要件 AC-5・設計 §7）。
//

import SwiftUI
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        // 再構成で URL は変えない（毎回新しい sheet を提示する設計のため更新不要）。
    }
}
