//
//  DSColor.swift
//  NewsListenApp
//
//  Editorial デザインシステムのカラートークン。
//  色の直値（.blue 等）を View に散らさず、ここを単一の真実として参照する。
//  ライト/ダークは UIColor の動的プロバイダで一括解決し、両モードを常に同時に定義する。
//

import SwiftUI
import UIKit

/// Editorial（雑誌風）テーマのカラートークン。
///
/// 「温かみのある紙（paper）＋墨（ink）＋1アクセント（朱）」の構成。各トークンは
/// ライト/ダークの2値を持ち、`UIColor` の `init(dynamicProvider:)` で実行時に解決する。
/// View からは `Color` として参照する（例: `DSColor.ink`）。
enum DSColor {
    /// 画面全体の背景（紙）。ライト=温白 / ダーク=墨黒。
    static let paper = adaptive(light: 0xFBF9F4, dark: 0x14130F)
    /// カードなど一段持ち上げた面。ライト=白 / ダーク=やや明るい墨。
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1E1C17)
    /// 主テキスト（墨）。
    static let ink = adaptive(light: 0x1C1A17, dark: 0xF4F0E7)
    /// 副次テキスト（ソース・日時などメタ情報）。
    static let inkSecondary = adaptive(light: 0x6E665B, dark: 0xABA496)
    /// 三次テキスト（最も控えめな補助情報）。
    static let inkTertiary = adaptive(light: 0x9A9286, dark: 0x756E61)
    /// 罫線・区切り線。
    static let hairline = adaptive(light: 0xE7E2D8, dark: 0x322F28)
    /// アクセント（マストヘッドの朱）。強調・関連スコア・主要操作に使う。
    static let accent = adaptive(light: 0xA8402E, dark: 0xE08A6E)
    /// アクセントの淡い面（バッジ背景など）。アクセントを低不透明度で敷く。
    static let accentSoft = adaptiveAlpha(light: 0xA8402E, lightAlpha: 0.10,
                                          dark: 0xE08A6E, darkAlpha: 0.16)

    /// UIKit 外観（`UINavigationBar` 等）設定用の `UIColor` 版トークン。
    enum UI {
        /// 紙（背景）。`DSColor.paper` の UIColor 版。
        static let paper = dynamic(light: 0xFBF9F4, dark: 0x14130F)
        /// 墨（主テキスト）。`DSColor.ink` の UIColor 版。
        static let ink = dynamic(light: 0x1C1A17, dark: 0xF4F0E7)
    }

    /// 16進2値からライト/ダーク適応 `UIColor` を生成する。
    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }

    /// 16進2値からライト/ダーク適応 `Color` を生成する。
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// 不透明度付きのライト/ダーク適応 `Color` を生成する。
    private static func adaptiveAlpha(light: UInt32, lightAlpha: CGFloat,
                                      dark: UInt32, darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: dark).withAlphaComponent(darkAlpha)
                : UIColor(hex: light).withAlphaComponent(lightAlpha)
        })
    }
}

private extension UIColor {
    /// `0xRRGGBB` 形式の整数から不透明 `UIColor` を生成する。
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
