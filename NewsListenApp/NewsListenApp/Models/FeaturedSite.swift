//
//  FeaturedSite.swift
//  NewsListenApp
//
//  バックエンド FeaturedSitesResponse（sites: [{id, name, url, thumbnail_url, description}]）に
//  対応する Codable モデル。システム提供のおすすめサイトを表す。
//

import Foundation

/// システム提供のおすすめサイト1件。バックエンドの `FeaturedSitesResponse` 内の要素に対応する。
struct FeaturedSite: Codable, Identifiable {
    /// Firestore doc id（slug）。Identifiable の一意キー。
    let id: String
    /// サイトの表示名。
    let name: String
    /// RSS フィードの URL。購読時に RssSource の url として使う。
    let url: String
    /// サムネイル画像 URL（任意）。
    let thumbnailURL: String?
    /// 説明文（任意）。
    let description: String?

    /// snake_case な API レスポンスとのマッピング。
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case thumbnailURL = "thumbnail_url"
        case description
    }
}

/// `/settings/featured-sources` エンドポイントのレスポンス。おすすめサイトの一覧を保持する。
struct FeaturedSitesResponse: Codable {
    /// おすすめサイト一覧（order 昇順でサーバから返る）。
    let sites: [FeaturedSite]
}

/// `/settings/onboarding` エンドポイントのレスポンス。初回オンボーディング完了状態を保持する。
struct OnboardingStatusResponse: Codable {
    /// 初回オンボーディング（おすすめ追加ステップ）が完了済みか。
    let onboardingCompleted: Bool

    /// snake_case な API レスポンスとのマッピング。
    enum CodingKeys: String, CodingKey {
        case onboardingCompleted = "onboarding_completed"
    }
}
