import Foundation

/// 層の所属表と依存方向の検査（`ArchitectureOracleTests`）が共有する宣言。
/// 正本は iOS 実装 Spec（target-architecture）§3.1・§4・§7。ここに無い集合を足さない。
enum ArchitectureLayer: String, CaseIterable {
    case compositionRoot, domain, application, adapter, presentation
}

enum ArchitectureManifest {
    /// §3.1 の所属表。5 つの規則を**全部**評価し、当たった規則の層で決める（順に当てて最初で止めない）。
    /// 正規表現は相対 path に対して照合する。5 規則と 5 層は 1 対 1 で、同じ規則の複数パターンは 1 層に数える。
    static let layerRules: [(pattern: String, layer: ArchitectureLayer)] = [
        (#"^NewsListenAppApp\.swift$"#, .compositionRoot),
        (#"(^|/)Domain/"#, .domain),
        (#"(^|/)Application/"#, .application),
        (#"^Podcast/Playback/[^/]+\.swift$"#, .application),
        (#"^AppState\.swift$"#, .application),
        (#"^Auth/SubjectCleanup\.swift$"#, .application),
        (#"^Networking/"#, .adapter),
        (#"^Models/"#, .adapter),
        (#"(^|/)Platform/"#, .adapter),
        (#"^Observability/"#, .adapter),
        (#"^Settings/PreferenceRegistry\.swift$"#, .adapter),
        (#"^Push/PushSupport\.swift$"#, .adapter),
        (#"(^|/)[^/]*View\.swift$"#, .presentation),
        (#"(^|/)[^/]*ViewModel\.swift$"#, .presentation),
        (#"(^|/)[^/]*Sheet[^/]*\.swift$"#, .presentation),
        (#"(^|/)[^/]*Card\.swift$"#, .presentation),
        (#"^DesignSystem/"#, .presentation),
        (#"^Utilities/"#, .presentation),
        (#"^Shared/Presentation/"#, .presentation),
        (#"^Push/AppDelegate\.swift$"#, .presentation),
        (#"^Feed/SafariView\.swift$"#, .presentation),
    ]

    /// 明示の行（完全一致の path → 層）。layerRules の結果を上書きする。
    /// 混在ファイルと、規則に当たらないファイルを割り当てる。目標の path へ移した slice でその行を消す。
    static let explicitLayers: [String: ArchitectureLayer] = [
        // domain
        "Models/FeaturedCategory.swift": .domain,
        // application
        "Passkey/PasskeyAuthorizationProviding.swift": .application,
        // adapter（5 規則のどれにも当たらないもの）
        "Passkey/PasskeyModels.swift": .adapter,
        "Sessions/SessionModels.swift": .adapter,
        "Passkey/PasskeyOptionsDecoder.swift": .adapter,
        "Passkey/PasskeyCredentialEncoder.swift": .adapter,
        "Passkey/ASAuthorizationPasskeyProvider.swift": .adapter,
    ]

    /// リードモデルのファイル（ios-dep-09 の対象）。初版は空。
    static let readModelFiles: Set<String> = []

    /// port を定義するファイル（ios-dep-11 の対象）。
    static let portFiles: Set<String> = [
        "Podcast/Playback/AudioEngine.swift",
        "Podcast/Playback/NowPlayingCenter.swift",
        "Podcast/Playback/PlaybackLifecycle.swift",
        "Passkey/PasskeyAuthorizationProviding.swift",
    ]

    /// domain の型だけを対象にするテストファイル（ios-check-08 の対象。`NewsListenAppTests/` からの相対）。
    static let domainTestFiles: Set<String> = [
        "TranscriptTimingTests.swift",
        "PlaybackQueueTests.swift",
        "PlaybackQueueConformanceTests.swift",
        "EpisodeTests.swift",
        "EpisodeContentTests.swift",
    ]

    /// ios-dep-12 の恒久の許可リスト（入力の下書き 6 個）。
    static let publishedDraftAllowlist: [(file: String, name: String)] = [
        ("Auth/LoginViewModel.swift", "username"),
        ("Auth/LoginViewModel.swift", "password"),
        ("Admin/AdminUsersViewModel.swift", "newUsername"),
        ("Admin/AdminUsersViewModel.swift", "newPassword"),
        ("Admin/AdminUsersViewModel.swift", "newDisplayName"),
        ("Admin/AdminUsersViewModel.swift", "newRole"),
    ]

    /// 一時経路 ios-temp-10: 現状の違反の許可リスト `(規則 ID, path, 行数)`。実測と一致することを要求する。
    /// 行番号は書かない（後の slice で動く）。減らした slice が同じ PR で一覧を減らす。
    static let allowlist: [(rule: String, path: String, lines: Int)] = [
        ("ios-dep-03", "AppState.swift", 18),
        ("ios-dep-13", "AppState.swift", 5),
        ("ios-dep-13", "Auth/LoginView.swift", 1),
        ("ios-dep-13", "Feed/FeedViewModel.swift", 1),
        ("ios-dep-13", "Observability/CrashReporter.swift", 1),
        ("ios-dep-13", "Podcast/PodcastViewModel.swift", 4),
        ("ios-dep-13", "Settings/AccountSettingsView.swift", 1),
        ("ios-dep-13", "Settings/SettingsViewModel.swift", 2),
        ("ios-dep-13", "Starred/StarredViewModel.swift", 1),
        ("ios-dep-02", "Models/FeaturedCategory.swift", 2),
        ("ios-dep-04/DTO", "Auth/LoginView.swift", 1),
        ("ios-dep-04/DTO", "DesignSystem/Components/DSStreakToolbar.swift", 1),
        ("ios-dep-04/DTO", "DesignSystem/PreviewSupport.swift", 12),
        ("ios-dep-04/DTO", "Feed/ArticleRowView.swift", 1),
        ("ios-dep-04/DTO", "Feed/FeedView.swift", 2),
        ("ios-dep-04/DTO", "Feed/SwipeableArticleCard.swift", 1),
        ("ios-dep-04/DTO", "Learning/LearningView.swift", 5),
        ("ios-dep-04/DTO", "Onboarding/OnboardingSourcesView.swift", 1),
        ("ios-dep-04/DTO", "Podcast/AudioPlayerView.swift", 7),
        ("ios-dep-04/DTO", "Podcast/PodcastRowView.swift", 4),
        ("ios-dep-04/DTO", "Podcast/PodcastView.swift", 4),
        ("ios-dep-04/DTO", "Podcast/QueueSheet.swift", 1),
        ("ios-dep-04/DTO", "Podcast/QuizSheetView.swift", 11),
        ("ios-dep-04/DTO", "Settings/AccountSettingsView.swift", 1),
        ("ios-dep-04/DTO", "Settings/SettingsView.swift", 5),
        ("ios-dep-04/DTO", "Starred/StarredView.swift", 2),
        ("ios-dep-06/DTO", "Admin/AdminUsersViewModel.swift", 2),
        ("ios-dep-06/DTO", "Auth/LoginViewModel.swift", 2),
        ("ios-dep-06/DTO", "Feed/FeedViewModel.swift", 6),
        ("ios-dep-06/DTO", "Learning/LearningViewModel.swift", 3),
        ("ios-dep-06/DTO", "Onboarding/OnboardingSourcesViewModel.swift", 3),
        ("ios-dep-06/DTO", "Passkey/PasskeyCredentialsViewModel.swift", 1),
        ("ios-dep-06/DTO", "Passkey/PasskeyLoginViewModel.swift", 2),
        ("ios-dep-06/DTO", "Podcast/PodcastViewModel.swift", 14),
        ("ios-dep-06/DTO", "Sessions/SessionsViewModel.swift", 1),
        ("ios-dep-06/DTO", "Settings/SettingsViewModel.swift", 4),
        ("ios-dep-06/DTO", "Starred/StarredViewModel.swift", 2),
        ("ios-dep-08", "DesignSystem/PreviewSupport.swift", 2),
        ("ios-dep-08", "Podcast/QuizSheetView.swift", 1),
        ("ios-rule-catalog-01・ios-rule-catalog-02", "Podcast/PodcastRowView.swift", 3),
        ("ios-rule-playback-05", "Podcast/AudioPlayerView.swift", 2),
        ("ios-rule-playback-05", "Podcast/PodcastViewModel.swift", 2),
        ("ios-rule-playback-04", "Settings/SettingsView.swift", 1),
        ("ios-rule-account-01", "Admin/AdminUsersViewModel.swift", 1),
        ("ios-rule-account-01", "Settings/AccountSettingsView.swift", 1),
        ("ios-rule-account-05", "Admin/AdminUsersView.swift", 2),
        ("ios-rule-account-05", "Admin/AdminUsersViewModel.swift", 3),
        ("ios-rule-account-05", "Models/AuthModels.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Onboarding/OnboardingSourcesViewModel.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Passkey/PasskeyCredentialsViewModel.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Passkey/PasskeyRegistrationViewModel.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Podcast/QuizSheetView.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Sessions/SessionsViewModel.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Settings/SettingsViewModel.swift", 1),
        ("ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", "Starred/StarredViewModel.swift", 1),
        ("ios-rule-prefs-01", "Settings/PreferenceRegistry.swift", 1),
        ("ios-rule-prefs-01", "Settings/SettingsView.swift", 6),
        ("ios-rule-prefs-01", "Utilities/DifficultyLabel.swift", 7),
        ("ios-rule-prefs-02", "Settings/PreferenceRegistry.swift", 1),
        ("ios-rule-prefs-02", "Settings/SettingsView.swift", 1),
        ("ios-rule-prefs-02", "Settings/SettingsViewModel.swift", 1),
        ("ios-rule-prefs-03", "Feed/ArticleRowView.swift", 1),
        ("ios-rule-prefs-03", "Feed/SwipeableArticleCard.swift", 1),
        ("ios-rule-prefs-03", "Podcast/PodcastRowView.swift", 1),
        ("ios-rule-prefs-03", "Settings/PreferenceRegistry.swift", 2),
        ("ios-rule-prefs-03", "Settings/SettingsView.swift", 2),
        ("ios-rule-curation-03", "Settings/SettingsView.swift", 1),
        ("ios-rule-learning-07", "Podcast/QuizSheetView.swift", 1),
        ("ios-rule-learning-05", "Models/VocabularyModels.swift", 1),
        ("ios-dep-05", "DesignSystem/PreviewSupport.swift", 6),
        ("ios-dep-05", "Feed/FeedView.swift", 3),
        ("ios-dep-05", "NewsListenAppApp.swift", 1),
        ("ios-dep-05", "Podcast/PodcastView.swift", 2),
        ("ios-dep-05", "Settings/SettingsView.swift", 5),
        ("ios-dep-05", "Starred/StarredView.swift", 2),
        ("ios-dep-04", "Admin/AdminUsersView.swift", 1),
        ("ios-dep-04", "Auth/LoginView.swift", 1),
        ("ios-dep-04", "DesignSystem/DSFeedback.swift", 2),
        ("ios-dep-04", "DesignSystem/PreviewSupport.swift", 2),
        ("ios-dep-04", "Feed/FeedView.swift", 1),
        ("ios-dep-04", "Learning/LearningView.swift", 3),
        ("ios-dep-04", "Learning/VocabularyTestView.swift", 3),
        ("ios-dep-04", "Onboarding/OnboardingSourcesView.swift", 1),
        ("ios-dep-04", "Podcast/QuizSheetView.swift", 1),
        ("ios-dep-04", "Settings/AccountSettingsView.swift", 2),
        ("ios-dep-04", "Settings/SettingsView.swift", 2),
        ("ios-dep-04", "Starred/StarredView.swift", 1),
        ("ios-dep-06", "Admin/AdminUsersViewModel.swift", 2),
        ("ios-dep-06", "Auth/LoginViewModel.swift", 2),
        ("ios-dep-06", "Feed/FeedViewModel.swift", 2),
        ("ios-dep-06", "Learning/LearningViewModel.swift", 3),
        ("ios-dep-06", "Learning/VocabularyTestViewModel.swift", 6),
        ("ios-dep-06", "Onboarding/OnboardingSourcesViewModel.swift", 2),
        ("ios-dep-06", "Passkey/PasskeyCredentialsViewModel.swift", 2),
        ("ios-dep-06", "Passkey/PasskeyLoginViewModel.swift", 2),
        ("ios-dep-06", "Passkey/PasskeyRegistrationViewModel.swift", 2),
        ("ios-dep-06", "Podcast/PodcastViewModel.swift", 14),
        ("ios-dep-06", "Sessions/SessionsViewModel.swift", 2),
        ("ios-dep-06", "Settings/SettingsViewModel.swift", 6),
        ("ios-dep-06", "Starred/StarredViewModel.swift", 2),
        ("ios-dep-12", "Admin/AdminUsersViewModel.swift", 1),
        ("ios-dep-12", "AppState.swift", 10),
        ("ios-dep-12", "Auth/LoginViewModel.swift", 1),
        ("ios-dep-12", "Feed/FeedViewModel.swift", 7),
        ("ios-dep-12", "Onboarding/OnboardingSourcesViewModel.swift", 2),
        ("ios-dep-12", "Passkey/PasskeyCredentialsViewModel.swift", 1),
        ("ios-dep-12", "Passkey/PasskeyLoginViewModel.swift", 1),
        ("ios-dep-12", "Passkey/PasskeyRegistrationViewModel.swift", 1),
        ("ios-dep-12", "Podcast/PodcastViewModel.swift", 9),
        ("ios-dep-12", "Sessions/SessionsViewModel.swift", 2),
        ("ios-dep-12", "Settings/SettingsViewModel.swift", 4),
        ("ios-dep-12", "Starred/StarredViewModel.swift", 3),
    ]

    /// 型名の集合。`DTO` は adapter のファイルの宣言から毎回作る（`dtoTypeNames(in:)`）。
    static let adapterConcrete: Set<String> = [
        "APIClient", "KeychainSessionStore", "AudioCacheManager", "MediaPlayerNowPlaying",
        "AVPlayerEngine", "NetworkMonitor", "PreferenceRegistry", "CrashReporter",
        "ASAuthorizationPasskeyProvider",
    ]

    /// `@AppStorage` は属性として照合する（`@AppStorage\b`）。ほかは単語境界の型名。
    static let uiFacility: Set<String> = [
        "DSFeedback", "UIApplication", "UIAccessibility", "Timer", "UserDefaults", "@AppStorage",
    ]

    /// 与えたファイルのコメント行以外にある `Codable`/`Decodable`/`Encodable` 適合の型宣言の型名。
    static func dtoTypeNames(in files: [URL]) -> Set<String> {
        let pattern = #"^\s*(struct|enum|final class|class)\s+(\w+)[^{]*:\s*[^{]*\b(Codable|Decodable|Encodable)\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var names: Set<String> = []
        for file in files {
            for line in SourceGrep.content(of: file).components(separatedBy: "\n") {
                if SourceGrep.isCommentLine(line) { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      let nameRange = Range(match.range(at: 2), in: line) else { continue }
                names.insert(String(line[nameRange]))
            }
        }
        return names
    }

    /// 明示の行にあればその層。無ければ layerRules のうち当たった規則の層の集合（0 個・1 個・2 個以上）。
    static func matchedLayers(of relativePath: String) -> Set<ArchitectureLayer> {
        if let explicit = explicitLayers[relativePath] { return [explicit] }
        var layers: Set<ArchitectureLayer> = []
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        for rule in layerRules {
            let regex = try! NSRegularExpression(pattern: rule.pattern)
            if regex.firstMatch(in: relativePath, range: range) != nil { layers.insert(rule.layer) }
        }
        return layers
    }

    /// matchedLayers がちょうど 1 つのときだけその層。0 個・2 個以上は nil。
    static func layer(of relativePath: String) -> ArchitectureLayer? {
        let layers = matchedLayers(of: relativePath)
        return layers.count == 1 ? layers.first : nil
    }
}
