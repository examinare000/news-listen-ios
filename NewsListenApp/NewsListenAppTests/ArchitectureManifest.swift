import Foundation

/// 層の所属表と依存方向の検査（`ArchitectureOracleTests`）が共有する宣言。
/// 正本は iOS 実装 Spec（target-architecture）§3.1・§4・§7。ここに無い集合を足さない。
enum ArchitectureLayer: String, CaseIterable {
    case compositionRoot, domain, application, adapter, presentation
}

/// 公開操作の台帳（ios-check-15 (a)）の kind。`id` は TA Spec §5 の `ios-cmd-*`・`ios-query-*`。
enum OperationKind: Equatable {
    case command(String)
    case query(String)
    case port
    case `internal`
    case readModel
    case factory
}

/// 台帳 1 行。型の直下の宣言 1 つに対応する。
typealias OperationRow = (file: String, type: String, name: String, kind: OperationKind)

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

    /// リードモデルのファイル（ios-dep-09 の対象）。
    static let readModelFiles: Set<String> = [
        "Podcast/Playback/NowPlaying.swift",
        "Catalog/Application/EpisodeRow.swift",
    ]

    /// port を定義するファイル（ios-dep-11 の対象）。
    static let portFiles: Set<String> = [
        "Podcast/Playback/AudioEngine.swift",
        "Podcast/Playback/NowPlayingCenter.swift",
        "Podcast/Playback/PlaybackLifecycle.swift",
        "Podcast/Playback/OfflineLibrary.swift",
        "Passkey/PasskeyAuthorizationProviding.swift",
        "Catalog/Application/EpisodeCatalog.swift",
        "Auth/Application/AccountProfile.swift",
    ]

    /// domain の型だけを対象にするテストファイル（ios-check-08 の対象。`NewsListenAppTests/` からの相対）。
    static let domainTestFiles: Set<String> = [
        "TranscriptTimingTests.swift",
        "PlaybackQueueTests.swift",
        "PlaybackQueueConformanceTests.swift",
        "EpisodeTests.swift",
        "EpisodeContentTests.swift",
        "PlayableEpisodeTests.swift",
        "PlaybackRulesTests.swift",
        "SubjectTests.swift",
        "PasswordPolicyTests.swift",
    ]

    /// application の層の公開宣言の台帳（ios-check-15 (a)）。実コードと双方向に照合する。
    static let operationLedger: [OperationRow] = [
        (file: "AppState.swift", type: "ArticleOpenMode", name: "id", kind: .readModel),
        (file: "AppState.swift", type: "ArticleOpenMode", name: "label", kind: .readModel),
        (file: "AppState.swift", type: "LoginReceipt", name: "token", kind: .readModel),
        (file: "AppState.swift", type: "LoginReceipt", name: "subject", kind: .readModel),
        (file: "AppState.swift", type: "AppState", name: "apiBaseURL", kind: .query("ios-query-account-03")),
        (file: "AppState.swift", type: "AppState", name: "apiKey", kind: .query("ios-query-account-03")),
        (file: "AppState.swift", type: "AppState", name: "session", kind: .query("ios-query-account-01")),
        (file: "AppState.swift", type: "AppState", name: "currentSubject", kind: .query("ios-query-account-01")),
        (file: "AppState.swift", type: "AppState", name: "subjectStamp", kind: .query("ios-query-account-01")),
        (file: "AppState.swift", type: "AppState", name: "isCurrentSubject(_:)", kind: .query("ios-query-account-01")),
        (file: "AppState.swift", type: "AppState", name: "defaultDifficulty", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "defaultPlaybackSpeed", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "weeklyGoalEpisodes", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "lastConfirmedWeeklyGoalEpisodes", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "articleOpenMode", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "timeFormat", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "onboardingCompleted", kind: .query("ios-query-sources-02")),
        (file: "AppState.swift", type: "AppState", name: "preferencesSyncFailed", kind: .query("ios-query-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "listeningStreak", kind: .query("ios-query-learning-03")),
        (file: "AppState.swift", type: "AppState", name: "listeningStreakLoadFailed", kind: .query("ios-query-learning-03")),
        (file: "AppState.swift", type: "AppState", name: "selectedPodcastId", kind: .query("ios-query-notify-01")),
        (file: "AppState.swift", type: "AppState", name: "lastCleanupIncomplete", kind: .query("ios-query-account-01")),
        (file: "AppState.swift", type: "AppState", name: "apnsDeviceToken", kind: .internal),
        (file: "AppState.swift", type: "AppState", name: "apiClient", kind: .query("ios-query-account-03")),
        (file: "AppState.swift", type: "AppState", name: "isConfigured", kind: .query("ios-query-account-01")),
        (file: "AppState.swift", type: "AppState", name: "completeLogin(_:)", kind: .command("ios-cmd-account-02")),
        (file: "AppState.swift", type: "AppState", name: "updateCurrentSubject(_:capturedAt:)", kind: .command("ios-cmd-account-10")),
        (file: "AppState.swift", type: "AppState", name: "retryResolve()", kind: .command("ios-cmd-account-04")),
        (file: "AppState.swift", type: "AppState", name: "handle(failure:sentToken:)", kind: .command("ios-cmd-account-04")),
        (file: "AppState.swift", type: "AppState", name: "didRegisterDeviceToken(_:)", kind: .command("ios-cmd-notify-01")),
        (file: "AppState.swift", type: "AppState", name: "registerDeviceTokenIfPossible()", kind: .command("ios-cmd-notify-01")),
        (file: "AppState.swift", type: "AppState", name: "handleNotificationPodcastId(_:)", kind: .command("ios-cmd-notify-02")),
        (file: "AppState.swift", type: "AppState", name: "refreshAuth()", kind: .command("ios-cmd-account-03")),
        (file: "AppState.swift", type: "AppState", name: "refreshPreferences()", kind: .command("ios-cmd-prefs-04")),
        (file: "AppState.swift", type: "AppState", name: "refreshListeningStreak()", kind: .command("ios-cmd-learning-05")),
        (file: "AppState.swift", type: "AppState", name: "confirmWeeklyGoalSync(_:capturedAt:)", kind: .command("ios-cmd-prefs-01")),
        (file: "AppState.swift", type: "AppState", name: "logout()", kind: .command("ios-cmd-account-04")),
        (file: "AppState.swift", type: "AppState", name: "registerPlaybackLifecycle(_:)", kind: .command("ios-cmd-account-11")),
        (file: "AppState.swift", type: "AppState", name: "refreshOnboardingStatus()", kind: .query("ios-query-sources-02")),
        (file: "AppState.swift", type: "AppState", name: "completeOnboarding()", kind: .command("ios-cmd-sources-03")),
        (file: "AppState.swift", type: "AppState", name: "init(sessionStore:apiClientOverride:apiClientFactory:preferences:nowPlayingCenter:clearOfflineLibrary:)", kind: .factory),
        (file: "Auth/SubjectCleanup.swift", type: "SubjectCleanup", name: "playbackLifecycle", kind: .internal),
        (file: "Auth/SubjectCleanup.swift", type: "SubjectCleanup", name: "nowPlayingCenter", kind: .internal),
        (file: "Auth/SubjectCleanup.swift", type: "SubjectCleanup", name: "clearSubjectPreferences", kind: .internal),
        (file: "Auth/SubjectCleanup.swift", type: "SubjectCleanup", name: "clearOfflineLibrary", kind: .internal),
        (file: "Auth/SubjectCleanup.swift", type: "SubjectCleanup", name: "run()", kind: .command("ios-cmd-account-04")),
        (file: "Auth/Application/AccountProfile.swift", type: "AccountGateway", name: "updateProfile", kind: .port),
        (file: "Auth/Application/AccountProfile.swift", type: "AccountGateway", name: "changePassword", kind: .port),
        (file: "Auth/Application/AccountProfile.swift", type: "AccountProfile", name: "init(gateway:)", kind: .factory),
        (file: "Auth/Application/AccountProfile.swift", type: "AccountProfile", name: "updateDisplayName(_:)", kind: .command("ios-cmd-account-05")),
        (file: "Auth/Application/AccountProfile.swift", type: "AccountProfile", name: "changePassword(current:new:)", kind: .command("ios-cmd-account-06")),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "load(url:)", kind: .port),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "play()", kind: .port),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "pause()", kind: .port),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "seek(to:)", kind: .port),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "setRate(_:)", kind: .port),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "stop()", kind: .port),
        (file: "Podcast/Playback/AudioEngine.swift", type: "AudioEngine", name: "events", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "RemoteCommandRegistration", name: "init(removal:)", kind: .factory),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "RemoteCommandRegistration", name: "isCancelled", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "RemoteCommandRegistration", name: "cancel()", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingSnapshot", name: "title", kind: .readModel),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingSnapshot", name: "subtitle", kind: .readModel),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingSnapshot", name: "elapsed", kind: .readModel),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingSnapshot", name: "duration", kind: .readModel),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingSnapshot", name: "rate", kind: .readModel),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingSnapshot", name: "isPlaying", kind: .readModel),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingCenter", name: "update(_:)", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingCenter", name: "updateElapsed(_:duration:)", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingCenter", name: "clear()", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingCenter", name: "registerCommands(_:)", kind: .port),
        (file: "Podcast/Playback/NowPlayingCenter.swift", type: "NowPlayingCenter", name: "unregister(_:)", kind: .port),
        (file: "Podcast/Playback/PlaybackLifecycle.swift", type: "PlaybackLifecycle", name: "stopForLogout()", kind: .port),
        (file: "Passkey/PasskeyAuthorizationProviding.swift", type: "PasskeyAuthorizationProviding", name: "createCredential(_:)", kind: .port),
        (file: "Passkey/PasskeyAuthorizationProviding.swift", type: "PasskeyAuthorizationProviding", name: "assertCredential(_:)", kind: .port),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "init(engine:)", kind: .factory),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "state", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "observe(_:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "start(episode:url:resumePosition:speed:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "play()", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "pause()", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "seek(to:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "seekRelative(_:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "setSpeed(_:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "stop()", kind: .internal),
        (file: "Podcast/Playback/PlaybackSession.swift", type: "PlaybackSession", name: "fail(episodeId:reason:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "session", kind: .query("ios-query-playback-03")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "presentation", kind: .query("ios-query-playback-03")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "queue", kind: .query("ios-query-playback-03")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "notice", kind: .query("ios-query-playback-03")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "isAdvancing", kind: .query("ios-query-playback-03")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "init(engine:nowPlayingCenter:library:reporter:fetchEpisode:isOnline:defaultSpeed:lockScreenSubtitle:beginBackgroundTask:)", kind: .factory),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "startEpisode(_:expandsPlayer:)", kind: .command("ios-cmd-playback-01")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "startEpisode(id:)", kind: .command("ios-cmd-playback-02")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "replayCurrent()", kind: .command("ios-cmd-playback-03")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "retry()", kind: .command("ios-cmd-playback-04")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "togglePlayPause()", kind: .command("ios-cmd-playback-05")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "seek(to:)", kind: .command("ios-cmd-playback-06")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "setSpeed(_:)", kind: .command("ios-cmd-playback-07")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "addToQueue(_:)", kind: .command("ios-cmd-playback-08")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "playNext(_:)", kind: .command("ios-cmd-playback-09")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "removeFromQueue(id:)", kind: .command("ios-cmd-playback-10")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "moveUpNext(fromOffsets:toOffset:)", kind: .command("ios-cmd-playback-11")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "skipToNext()", kind: .command("ios-cmd-playback-12")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "dismissError()", kind: .command("ios-cmd-playback-13")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "stopForLogout()", kind: .command("ios-cmd-playback-14")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "minimizePlayer()", kind: .command("ios-cmd-playback-15")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "expandPlayer()", kind: .command("ios-cmd-playback-16")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "stop()", kind: .command("ios-cmd-playback-22")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "nowPlaying()", kind: .query("ios-query-playback-01")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "upNext()", kind: .query("ios-query-playback-02")),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "onEnded(endedId:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackCoordinator.swift", type: "PlaybackCoordinator", name: "previewSet(session:queue:)", kind: .internal),
        (file: "Podcast/Playback/PlaybackCoordinator+Preview.swift", type: "PlaybackCoordinator", name: "previewParts(session:queue:)", kind: .factory),
        (file: "Podcast/Playback/NowPlaying.swift", type: "QueueEntry", name: "episodeId", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "QueueEntry", name: "id", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "QueueEntry", name: "introText", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "QueueEntry", name: "difficulty", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "QueueEntry", name: "durationSeconds", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "episodeId", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "id", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "displayTitle", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "japaneseIntroText", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "segments", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "vocabulary", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "quiz", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "difficulty", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "sourceArticles", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "sourceKind", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "hasTranscript", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "hasVocabulary", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "hasQuiz", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "hasSourceArticles", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "showsCcBySaLicense", kind: .readModel),
        (file: "Podcast/Playback/NowPlaying.swift", type: "NowPlaying", name: "queueEntry", kind: .readModel),
        (file: "Podcast/Playback/PositionReporter.swift", type: "PositionReporter", name: "lastSyncFailure", kind: .query("ios-query-playback-05")),
        (file: "Podcast/Playback/PositionReporter.swift", type: "PositionReporter", name: "init(updatePosition:markCompleted:onPositionSaved:onCompletionRecorded:beginBackgroundTask:now:)", kind: .factory),
        (file: "Podcast/Playback/PositionReporter.swift", type: "PositionReporter", name: "attach(_:)", kind: .internal),
        (file: "Podcast/Playback/PositionReporter.swift", type: "PositionReporter", name: "listenCompleted(id:)", kind: .internal),
        (file: "Podcast/Playback/PositionReporter.swift", type: "PositionReporter", name: "flush()", kind: .command("ios-cmd-playback-17")),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "AudioFileStore", name: "url", kind: .port),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "AudioFileStore", name: "exists", kind: .port),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "AudioFileStore", name: "write", kind: .port),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "AudioFileStore", name: "remove", kind: .port),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "AudioFileStore", name: "removeAll", kind: .port),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "AudioFileStore", name: "size", kind: .port),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "savedIds", kind: .query("ios-query-playback-04")),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "usage()", kind: .query("ios-query-playback-04")),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "init(store:)", kind: .factory),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "save(_:for:)", kind: .internal),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "has(_:)", kind: .internal),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "url(_:)", kind: .internal),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "remove(_:)", kind: .internal),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "clearAll()", kind: .internal),
        (file: "Podcast/Playback/OfflineLibrary.swift", type: "OfflineLibrary", name: "refresh(candidateIds:)", kind: .command("ios-cmd-playback-21")),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "downloadingIds", kind: .query("ios-query-playback-04")),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "init(library:fetchEpisode:downloadAudio:)", kind: .factory),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "download(episodeId:)", kind: .command("ios-cmd-playback-18")),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "remove(episodeId:)", kind: .command("ios-cmd-playback-19")),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "removeAll()", kind: .command("ios-cmd-playback-19")),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "cancelAll()", kind: .command("ios-cmd-playback-20")),
        (file: "Podcast/Playback/OfflineDownloads.swift", type: "OfflineDownloads", name: "state(for:)", kind: .query("ios-query-playback-04")),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "episodeId", kind: .readModel),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "id", kind: .readModel),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "title", kind: .readModel),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "difficulty", kind: .readModel),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "durationSeconds", kind: .readModel),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "createdAt", kind: .readModel),
        (file: "Catalog/Application/EpisodeRow.swift", type: "EpisodeRow", name: "badge", kind: .readModel),
        (file: "Catalog/Application/EpisodeCatalog.swift", type: "CatalogGateway", name: "fetchEpisodes", kind: .port),
        (file: "Catalog/Application/EpisodeCatalog.swift", type: "EpisodeCatalog", name: "rows", kind: .query("ios-query-catalog-01")),
        (file: "Catalog/Application/EpisodeCatalog.swift", type: "EpisodeCatalog", name: "reload()", kind: .query("ios-query-catalog-01")),
        (file: "Catalog/Application/EpisodeCatalog.swift", type: "EpisodeCatalog", name: "episode(id:)", kind: .query("ios-query-catalog-02")),
        (file: "Catalog/Application/EpisodeCatalog.swift", type: "EpisodeCatalog", name: "init(gateway:)", kind: .factory),
        (file: "Catalog/Application/EpisodeCatalog.swift", type: "EpisodeCatalog", name: "applyPositionSaved(_:)", kind: .command("ios-cmd-catalog-01")),
    ]

    /// TA Spec §5 の `ios-cmd-*`・`ios-query-*` の ID の全集合。
    static let specOperationIDs: Set<String> = [
        "ios-cmd-account-01",
        "ios-cmd-account-02",
        "ios-cmd-account-03",
        "ios-cmd-account-04",
        "ios-cmd-account-05",
        "ios-cmd-account-06",
        "ios-cmd-account-07",
        "ios-cmd-account-08",
        "ios-cmd-account-09",
        "ios-cmd-account-10",
        "ios-cmd-account-11",
        "ios-cmd-catalog-01",
        "ios-cmd-curation-01",
        "ios-cmd-curation-02",
        "ios-cmd-curation-03",
        "ios-cmd-curation-04",
        "ios-cmd-learning-01",
        "ios-cmd-learning-02",
        "ios-cmd-learning-03",
        "ios-cmd-learning-04",
        "ios-cmd-learning-05",
        "ios-cmd-notify-01",
        "ios-cmd-notify-02",
        "ios-cmd-observe-01",
        "ios-cmd-playback-01",
        "ios-cmd-playback-02",
        "ios-cmd-playback-03",
        "ios-cmd-playback-04",
        "ios-cmd-playback-05",
        "ios-cmd-playback-06",
        "ios-cmd-playback-07",
        "ios-cmd-playback-08",
        "ios-cmd-playback-09",
        "ios-cmd-playback-10",
        "ios-cmd-playback-11",
        "ios-cmd-playback-12",
        "ios-cmd-playback-13",
        "ios-cmd-playback-14",
        "ios-cmd-playback-15",
        "ios-cmd-playback-16",
        "ios-cmd-playback-17",
        "ios-cmd-playback-18",
        "ios-cmd-playback-19",
        "ios-cmd-playback-20",
        "ios-cmd-playback-21",
        "ios-cmd-playback-22",
        "ios-cmd-prefs-01",
        "ios-cmd-prefs-02",
        "ios-cmd-prefs-03",
        "ios-cmd-prefs-04",
        "ios-cmd-sources-01",
        "ios-cmd-sources-02",
        "ios-cmd-sources-03",
        "ios-query-account-01",
        "ios-query-account-02",
        "ios-query-account-03",
        "ios-query-catalog-01",
        "ios-query-catalog-02",
        "ios-query-curation-01",
        "ios-query-curation-02",
        "ios-query-curation-03",
        "ios-query-learning-01",
        "ios-query-learning-02",
        "ios-query-learning-03",
        "ios-query-learning-04",
        "ios-query-learning-05",
        "ios-query-notify-01",
        "ios-query-playback-01",
        "ios-query-playback-02",
        "ios-query-playback-03",
        "ios-query-playback-04",
        "ios-query-playback-05",
        "ios-query-prefs-01",
        "ios-query-sources-01",
        "ios-query-sources-02",
    ]

    /// 生成境界の検査（ios-check-16）の対象の型。
    static let validatedDomainTypes: Set<String> = [
        "PlayableEpisode",
        "ArticleOpenMode",
        "FeaturedCategory",
        "SubjectKey",
        "DifficultyLevel",
        "WeeklyGoalTarget",
        "TimeFormat",
        "GenerationAllowance",
        "VocabularyTest",
        "QuizAttempt",
    ]

    /// 読み書きが混ざった操作（TA Spec §6）。実コードの公開宣言に今もある数を追跡する。
    static let readWriteMixedOperations: [(file: String, type: String, name: String)] = [
        (file: "AppState.swift", type: "AppState", name: "refreshPreferences()"),
        (file: "AppState.swift", type: "AppState", name: "refreshListeningStreak()"),
        (file: "AppState.swift", type: "AppState", name: "refreshOnboardingStatus()"),
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
        ("ios-dep-03", "AppState.swift", 14),
        ("ios-dep-13", "AppState.swift", 5),
        ("ios-dep-13", "Auth/LoginView.swift", 1),
        ("ios-dep-13", "Feed/FeedViewModel.swift", 1),
        ("ios-dep-13", "Observability/CrashReporter.swift", 1),
        ("ios-dep-13", "Settings/AccountSettingsView.swift", 1),
        ("ios-dep-13", "Starred/StarredViewModel.swift", 1),
        ("ios-dep-02", "Models/FeaturedCategory.swift", 2),
        ("ios-dep-04/DTO", "DesignSystem/Components/DSStreakToolbar.swift", 1),
        ("ios-dep-04/DTO", "DesignSystem/PreviewSupport.swift", 5),
        ("ios-dep-04/DTO", "Feed/ArticleRowView.swift", 1),
        ("ios-dep-04/DTO", "Feed/FeedView.swift", 2),
        ("ios-dep-04/DTO", "Feed/SwipeableArticleCard.swift", 1),
        ("ios-dep-04/DTO", "Learning/LearningView.swift", 5),
        ("ios-dep-04/DTO", "Onboarding/OnboardingSourcesView.swift", 1),
        ("ios-dep-04/DTO", "Podcast/AudioPlayerView.swift", 1),
        ("ios-dep-04/DTO", "Podcast/PodcastRowView.swift", 2),
        ("ios-dep-04/DTO", "Podcast/PodcastView.swift", 4),
        ("ios-dep-04/DTO", "Podcast/QuizSheetView.swift", 7),
        ("ios-dep-04/DTO", "Settings/AccountSettingsView.swift", 1),
        ("ios-dep-04/DTO", "Settings/SettingsView.swift", 5),
        ("ios-dep-04/DTO", "Starred/StarredView.swift", 2),
        ("ios-dep-06/DTO", "Admin/AdminUsersViewModel.swift", 2),
        ("ios-dep-06/DTO", "Feed/FeedViewModel.swift", 6),
        ("ios-dep-06/DTO", "Learning/LearningViewModel.swift", 3),
        ("ios-dep-06/DTO", "Onboarding/OnboardingSourcesViewModel.swift", 3),
        ("ios-dep-06/DTO", "Passkey/PasskeyCredentialsViewModel.swift", 1),
        ("ios-dep-06/DTO", "Podcast/PodcastViewModel.swift", 3),
        ("ios-dep-06/DTO", "Sessions/SessionsViewModel.swift", 1),
        ("ios-dep-06/DTO", "Settings/SettingsViewModel.swift", 4),
        ("ios-dep-06/DTO", "Starred/StarredViewModel.swift", 2),
        ("ios-rule-account-05", "Admin/AdminUsersView.swift", 2),
        ("ios-rule-account-05", "Admin/AdminUsersViewModel.swift", 3),
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
        ("ios-dep-05", "Feed/FeedView.swift", 3),
        ("ios-dep-05", "NewsListenAppApp.swift", 1),
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
        ("ios-dep-04", "Settings/AccountSettingsView.swift", 1),
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
        ("ios-dep-06", "Podcast/PodcastViewModel.swift", 2),
        ("ios-dep-06", "Sessions/SessionsViewModel.swift", 2),
        ("ios-dep-06", "Settings/SettingsViewModel.swift", 4),
        ("ios-dep-06", "Starred/StarredViewModel.swift", 2),
        ("ios-dep-12", "Admin/AdminUsersViewModel.swift", 1),
        ("ios-dep-12", "AppState.swift", 10),
        ("ios-dep-12", "Auth/LoginViewModel.swift", 1),
        ("ios-dep-12", "Feed/FeedViewModel.swift", 7),
        ("ios-dep-12", "Onboarding/OnboardingSourcesViewModel.swift", 2),
        ("ios-dep-12", "Passkey/PasskeyCredentialsViewModel.swift", 1),
        ("ios-dep-12", "Passkey/PasskeyLoginViewModel.swift", 1),
        ("ios-dep-12", "Passkey/PasskeyRegistrationViewModel.swift", 1),
        ("ios-dep-12", "Sessions/SessionsViewModel.swift", 2),
        ("ios-dep-12", "Settings/SettingsViewModel.swift", 4),
        ("ios-dep-12", "Starred/StarredViewModel.swift", 3),
        // ios-check-16: 生成の入口が検査つきでない型（owner: ios-slice-prefs-01・ios-slice-periphery-02）。
        ("ios-check-16", "AppState.swift", 1),
        ("ios-check-16", "Models/FeaturedCategory.swift", 1),
        // ios-check-15 (b): query の契約テストがまだ無い ID（owner: ios-slice-closure-01・ios-slice-prefs-01・ios-slice-periphery-02・ios-slice-learning-03）。
        ("ios-check-15/verifies/ios-query-account-03", "AppState.swift", 3),
        ("ios-check-15/verifies/ios-query-prefs-01", "AppState.swift", 7),
        ("ios-check-15/verifies/ios-query-sources-02", "AppState.swift", 2),
        ("ios-check-15/verifies/ios-query-learning-03", "AppState.swift", 2),
        ("ios-check-15/verifies/ios-query-notify-01", "AppState.swift", 1),
        // ios-check-15: 読み書きが混ざった操作（owner: ios-slice-prefs-01・ios-slice-learning-03・ios-slice-periphery-02）。
        ("ios-check-15/read-write", "AppState.swift", 3),
    ]

    /// `@AppStorage` は属性として照合する（`@AppStorage\b`）。ほかは単語境界の型名。
    static let uiFacility: Set<String> = [
        "DSFeedback", "UIApplication", "UIAccessibility", "Timer", "UserDefaults", "@AppStorage",
    ]

    /// DTO（Codable 適合の型宣言）を認識する正規表現。`dtoTypeNames(in:)` と `ArchitectureScan.adapterInventory` が共有する正本。
    static let dtoDeclarationRegex = try! NSRegularExpression(
        pattern: #"^\s*(struct|enum|final class|class)\s+(\w+)[^{]*:\s*[^{]*\b(Codable|Decodable|Encodable)\b"#
    )

    /// 与えたファイルのコメント行以外にある `Codable`/`Decodable`/`Encodable` 適合の型宣言の型名。
    /// adapter の具象型は `ArchitectureScan.adapterInventory` が同じファイルから導出する。
    static func dtoTypeNames(in files: [URL]) -> Set<String> {
        let regex = dtoDeclarationRegex
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
