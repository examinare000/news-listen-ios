//
//  DSAppearance.swift
//  NewsListenApp
//
//  UIKit ベースのグローバル外観（ナビゲーションバー）を Editorial テーマに合わせる。
//  SwiftUI だけでは差し替えにくい大見出し書体を New York（serif）に統一し、
//  背景を紙（paper）に揃えてアプリ全体の一体感を出す。
//

import UIKit

/// アプリ起動時に一度だけ呼び、グローバル外観を Editorial テーマへ設定する。
enum DSAppearance {
    /// `UINavigationBar` の見出し書体（セリフ）と背景（紙）を適用する。
    static func configure() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = DSColor.UI.paper
        appearance.shadowColor = .clear

        appearance.largeTitleTextAttributes = [
            .font: serifFont(size: 34, weight: .bold),
            .foregroundColor: DSColor.UI.ink,
        ]
        appearance.titleTextAttributes = [
            .font: serifFont(size: 17, weight: .semibold),
            .foregroundColor: DSColor.UI.ink,
        ]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    /// New York（`design: .serif`）の `UIFont` を生成する。取得不可なら system にフォールバック。
    private static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
