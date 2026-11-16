//
//  PreviewSupport.swift
//  NewsListenApp
//
//  Xcode Previews 専用のサンプルデータとネットワークモック。
//  ログイン・実バックエンド無しで各画面を populated 状態で確認するために使う。
//  本番バイナリには含めない（全体を #if DEBUG で囲む）。
//

#if DEBUG
import Foundation
import SwiftUI

/// プレビュー用のサンプルモデルと、それらを返すモック群。
enum PreviewSamples {
    /// Feed プレビュー用のサンプル記事。ソース・スコア・長さに変化を付ける。
    static let articles: [ArticleCardModel] = [
        ArticleCardModel(
            id: "a1",
            title: "Fed signals rate pause as inflation cools toward target",
            url: "https://example.com/1",
            source: "Reuters",
            score: 0.92,
            publishedAt: "2026-06-29T06:30:00Z"
        ),
        ArticleCardModel(
            id: "a2",
            title: "UK economy returns to growth in surprise first-quarter rebound",
            url: "https://example.com/2",
            source: "BBC",
            score: 0.74,
            publishedAt: "2026-06-29T03:10:00Z"
        ),
        ArticleCardModel(
            id: "a3",
            title: "Chipmakers rally as demand for AI accelerators outpaces supply",
            url: "https://example.com/3",
            source: "Bloomberg",
            score: 0.58,
            publishedAt: "2026-06-28T21:45:00Z"
        ),
        ArticleCardModel(
            id: "a4",
            title: "Climate summit ends with new pledges on methane reduction",
            url: "https://example.com/4",
            source: "The Guardian",
            score: 0.33,
            publishedAt: "2026-06-28T18:00:00Z"
        ),
    ]

    /// Podcast プレビュー用のサンプル。再生可能/生成中/失敗の3状態を含める。
    /// p1 はトランスクリプト・語彙・クイズを含む完全版（AudioPlayerView プレビュー用）。
    static let episodes: [Episode] = {
        // p1: vocabulary と quiz を含む完全なエピソード
        let p1Content = EpisodeContent(
            id: "p1",
            title: "米連邦準備制度が利上げを見送り、英国経済が予想外の回復を見せた。",
            japaneseIntroText: "今日は米連邦準備制度の利上げ見送りと、英国経済の予想外の回復について取り上げます。",
            difficulty: "toeic_900",
            createdAt: "2026-06-29T07:00:00Z",
            durationSeconds: 247,
            segments: [
                TranscriptSegment(speaker: "A", text: "米連邦準備制度が今回の会合で利上げを見送りました。"),
                TranscriptSegment(speaker: "B", text: "一方、英国経済は予想外の回復を見せています。"),
            ],
            vocabulary: [
                VocabularyEntry(term: "pause", meaningJa: "一時中断する、中断期間", example: "The central bank will pause its rate hikes."),
                VocabularyEntry(term: "rebound", meaningJa: "反発、回復", example: "The UK economy showed a strong rebound in the first quarter."),
                VocabularyEntry(term: "inflation", meaningJa: "インフレーション、物価上昇", example: "Inflation has cooled toward the target."),
            ],
            quiz: [
                QuizQuestion(
                    question: "According to the podcast, why did the central bank pause its rate hikes?",
                    options: ["Inflation cooled toward the target", "The economy was growing too fast", "Interest rates were too high", "Banks requested a halt"]),
                QuizQuestion(
                    question: "How did the UK economy perform in the first quarter?",
                    options: ["It contracted sharply", "It showed an unexpected rebound", "It remained flat", "Growth slowed significantly"]),
                QuizQuestion(
                    question: "What is the main topic of today's podcast?",
                    options: ["Global stock market trends", "Central bank decisions and economic recovery", "Brexit negotiations", "Technology sector performance"]),
            ],
            sourceArticles: [
                PodcastSourceArticle(articleId: "a1", title: "Fed signals rate pause as inflation cools toward target", url: "https://example.com/1", source: "Reuters"),
                PodcastSourceArticle(articleId: "a2", title: "UK economy returns to growth in surprise first-quarter rebound", url: "not a url", source: "BBC"),
            ],
            sourceKind: "featured"
        )
        guard let p1 = PlayableEpisode(content: p1Content, audioUrl: "https://example.com/p1.mp3", serverPosition: 72) else {
            preconditionFailure("プレビューの標本 p1 は再生可能な種別であること")
        }

        return [
            .playable(p1),
            .generating(GeneratingEpisode(content: EpisodeContent(
                id: "p2",
                title: "",
                japaneseIntroText: "AI半導体の需要が供給を上回り、関連銘柄が上昇しています。",
                difficulty: "toeic_600",
                createdAt: "2026-06-28T22:30:00Z",
                durationSeconds: 188,
                segments: nil,
                vocabulary: nil,
                quiz: nil,
                sourceArticles: nil,
                sourceKind: nil
            ))),
            .failed(FailedEpisode(
                content: EpisodeContent(
                    id: "p3",
                    title: "",
                    japaneseIntroText: "気候サミットがメタン削減の新たな誓約とともに閉幕しました。",
                    difficulty: "eiken_2",
                    createdAt: "2026-06-28T19:00:00Z",
                    durationSeconds: 0,
                    segments: nil,
                    vocabulary: nil,
                    quiz: nil,
                    sourceArticles: nil,
                    sourceKind: nil
                ),
                reportedMessage: "音声生成に失敗しました"
            )),
        ]
    }()

    /// プレビュー用の `AppState`（API 未注入のまま動く。通信・保存・ロック画面は何もしない）。
    @MainActor static func appState() -> AppState {
        AppState(
            sessionStore: InMemorySessionStore(),
            accountGatewayFactory: { _, _ in nil },
            nowPlayingCenter: PreviewNowPlayingCenter(),
            clearOfflineLibrary: { _ in }
        )
    }

    /// プレビュー用の `PreferencesStore`（通信なし・保存なし。値は既定のまま）。
    @MainActor static func preferencesStore() -> PreferencesStore {
        let state = appState()
        return PreferencesStore(
            gateway: nil,
            storage: PreferenceStorage(
                read: {
                    PreferenceSnapshot(
                        difficulty: .default,
                        playbackSpeed: PreferenceCatalog.defaultPlaybackSpeed,
                        weeklyGoal: .default,
                        articleOpenMode: PreferenceCatalog.defaultArticleOpenMode,
                        timeFormat: .default,
                        soundEnabled: PreferenceCatalog.defaultSoundEnabled,
                        hapticsEnabled: PreferenceCatalog.defaultHapticsEnabled
                    )
                },
                write: { _ in },
                clearSubjectScoped: {}
            ),
            isCurrentSubject: { state.isCurrentSubject($0) },
            subjectStamp: { state.subjectStamp },
            isAuthenticated: { false }
        )
    }

    /// 通信なしで `articles` を返す Feed プレビュー用の `FeedCuration`（書込みは何もしない）。
    @MainActor static func feedCuration() -> FeedCuration {
        FeedCuration(gateway: curationGateway(), undoGracePeriod: .seconds(4), currentSubject: { nil })
    }

    /// 通信なしで `articles` を返す Starred プレビュー用の `StarredArticles`。
    @MainActor static func starredArticles() -> StarredArticles {
        StarredArticles(gateway: curationGateway())
    }

    private static func curationGateway() -> CurationGateway {
        CurationGateway(
            fetchFeed: { articles },
            star: { _, _ in },
            dismiss: { _ in },
            fetchStarred: { articles },
            unstar: { _ in },
            fetchAllowance: { nil }
        )
    }

    /// サンプル JSON を返すモックセッションで組んだ、ログインのプレビュー用 `Authentication`。
    @MainActor static func authentication() -> Authentication {
        Authentication(gateway: .live(apiClient: PreviewGateways.apiClient()))
    }

    /// ログインのプレビュー用 `PasskeySignIn`。認証器は常に未対応を返す。
    @MainActor static func passkeySignIn() -> PasskeySignIn {
        PasskeySignIn(gateway: .live(apiClient: PreviewGateways.apiClient()), provider: PreviewPasskeyProvider())
    }

    private struct PreviewPasskeyProvider: PasskeyAuthorizationProviding {
        func createCredential(_ options: PasskeyRegistrationOptions) async throws -> PasskeyRegistrationCredential {
            throw PasskeyError.notSupported
        }

        func assertCredential(_ options: PasskeyAssertionOptions) async throws -> PasskeyAssertionCredential {
            throw PasskeyError.notSupported
        }
    }

    /// 再生中状態を仕込んだ `PodcastViewModel`（プレイヤー UI 確認用）。
    @MainActor static func playerViewModel() -> PodcastViewModel {
        let episode = previewPlayable()
        return previewFacade(
            session: .playing(episode: episode, position: 72, duration: 247, speed: 1.0),
            queue: PlaybackQueue<Episode>(items: [.playable(episode)], currentIndex: 0))
    }

    /// 聴き終わり後のコンパクト表示を仕込んだ `PodcastViewModel`（finishedContent プレビュー用）。
    @MainActor static func finishedPlayerViewModel() -> PodcastViewModel {
        let episode = previewPlayable()
        return previewFacade(
            session: .ended(episode: episode, duration: 247),
            queue: PlaybackQueue<Episode>(items: [.playable(episode)], currentIndex: 0))
    }

    private static func previewPlayable() -> PlayableEpisode {
        guard case .playable(let episode) = episodes[0] else {
            preconditionFailure("プレビューの標本 p1 は再生可能な種別であること")
        }
        return episode
    }

    /// Coordinator・Reporter・保存庫は `previewParts` の「何もしない」実装。ダウンロードとネットワークもここで作る。
    @MainActor private static func previewFacade(session: PlaybackState, queue: PlaybackQueue<Episode>) -> PodcastViewModel {
        let parts = PlaybackCoordinator.previewParts(session: session, queue: queue)
        let downloads = OfflineDownloads(
            library: parts.library,
            fetchEpisode: { _ in throw CancellationError() },
            downloadAudio: { _ in throw CancellationError() },
            currentSubject: { nil })
        let catalog = EpisodeCatalog(gateway: CatalogGateway(fetchEpisodes: { episodes }))
        let learningGateway = LearningGateway.live(apiClient: PreviewGateways.apiClient())
        return PodcastViewModel(
            vocabularyBook: VocabularyBook(gateway: learningGateway),
            quizGrading: QuizGrading(gateway: learningGateway),
            catalog: catalog,
            coordinator: parts.coordinator,
            reporter: parts.reporter,
            positionRecords: parts.positionRecords,
            library: parts.library,
            downloads: downloads,
            networkMonitor: StubNetworkMonitor(),
            defaultSpeed: { 1.0 })
    }

    /// 通信なしで組む学習の port。`streakDays` があれば `fetchStreak` がその日数を返し、無ければ失敗する。
    private static func previewLearningGateway(streakDays: Int?) -> LearningGateway {
        LearningGateway(
            fetchVocabulary: { (terms: [], count: 0) },
            saveVocabulary: { _, _ in },
            fetchTestSession: { [] },
            submitTestResult: { _ in },
            submitQuiz: { _, _ in throw CancellationError() },
            fetchDashboard: { throw CancellationError() },
            fetchStreak: {
                guard let streakDays else { throw CancellationError() }
                return ListeningStreakStatus(days: streakDays, listenedToday: true, lastListenedDay: "2026-07-29")
            }
        )
    }

    /// `streakDays` があるとき、ストリークを 1 回取得した状態の `EngagementStore`。
    @MainActor static func engagement(streakDays: Int? = nil) -> EngagementStore {
        let state = appState()
        let store = EngagementStore(
            gateway: previewLearningGateway(streakDays: streakDays),
            seenStore: (read: { [] }, write: { _ in }),
            subjectStamp: { state.subjectStamp },
            isCurrentSubject: { _ in true }
        )
        if streakDays != nil {
            Task { await store.refreshStreak() }
        }
        return store
    }

    @MainActor static func vocabularyBook() -> VocabularyBook {
        VocabularyBook(gateway: previewLearningGateway(streakDays: nil))
    }

    @MainActor static func vocabularyTesting() -> VocabularyTesting {
        VocabularyTesting(gateway: previewLearningGateway(streakDays: nil))
    }
}


/// プレビュー用の `AppState` が受ける、何もしないロック画面 port。
private final class PreviewNowPlayingCenter: NowPlayingCenter {
    func update(_ snapshot: NowPlayingSnapshot) {}
    func updateElapsed(_ elapsed: Double, duration: Double) {}
    func clear() {}

    func registerCommands(
        _ handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult
    ) -> RemoteCommandRegistration {
        RemoteCommandRegistration(removal: {})
    }

    func unregister(_ registration: RemoteCommandRegistration) {}
}
#endif
