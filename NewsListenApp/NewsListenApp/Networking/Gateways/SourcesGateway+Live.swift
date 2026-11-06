//
//  SourcesGateway+Live.swift
//  NewsListenApp
//
//  RSS ソースとおすすめの port、Onboarding の完了の取得・記録を `APIClient` から組む adapter。
//  応答は `SourceEntry`・`FeaturedSiteCard` に変換して返す。
//

import Foundation

extension SourcesGateway {
    /// - Parameter client: 呼出のたびに現在の `APIClient` を返す。nil のとき読みと `add`・`update` は `[]`、
    ///   `remove` は何もせず成功。
    static func live(client: @escaping @MainActor () -> APIClient?) -> SourcesGateway {
        SourcesGateway(
            list: { @MainActor in
                guard let client = client() else { return [] }
                return try await client.fetchSources().sources.map { $0.toEntry() }
            },
            add: { @MainActor name, url in
                guard let client = client() else { return [] }
                return try await client.addSource(name: name, url: url).sources.map { $0.toEntry() }
            },
            update: { @MainActor oldURL, name, url in
                guard let client = client() else { return [] }
                return try await client.updateSource(oldURL: oldURL, name: name, url: url).sources.map { $0.toEntry() }
            },
            remove: { @MainActor url in
                guard let client = client() else { return }
                try await client.removeSource(url: url)
            },
            featured: { @MainActor in
                guard let client = client() else { return [] }
                return try await client.fetchFeaturedSites().sites.map { $0.toCard() }
            }
        )
    }
}

extension OnboardingProgress {
    /// - Parameter client: 呼出のたびに現在の `APIClient` を返す。nil のとき取得は値なし、記録は何もせず成功。
    static func live(
        client: @escaping @MainActor () -> APIClient?,
        subjectStamp: @escaping () -> SubjectStamp,
        isCurrentSubject: @escaping (SubjectStamp) -> Bool
    ) -> OnboardingProgress {
        OnboardingProgress(
            fetchStatus: { @MainActor in
                try await client()?.fetchOnboardingStatus().onboardingCompleted
            },
            recordCompleted: { @MainActor in
                _ = try await client()?.completeOnboarding()
            },
            subjectStamp: subjectStamp,
            isCurrentSubject: isCurrentSubject
        )
    }
}

private extension RssSource {
    func toEntry() -> SourceEntry {
        SourceEntry(name: name, url: url)
    }
}

private extension FeaturedSite {
    func toCard() -> FeaturedSiteCard {
        FeaturedSiteCard(
            id: id, name: name, url: url, thumbnailURL: thumbnailURL, description: description,
            category: FeaturedCategory.normalize(category)
        )
    }
}
