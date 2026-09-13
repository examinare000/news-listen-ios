import XCTest
@testable import NewsListenApp

final class ModelTests: XCTestCase {

    func testArticleDecodesFromJSON() throws {
        let json = """
        {
            "id": "abc123",
            "title": "Rust is amazing",
            "url": "https://example.com/rust",
            "source": "hackernews",
            "score": 0.9,
            "published_at": "2026-05-31T06:00:00Z"
        }
        """.data(using: .utf8)!

        let article = try JSONDecoder().decode(Article.self, from: json)
        XCTAssertEqual(article.id, "abc123")
        XCTAssertEqual(article.title, "Rust is amazing")
        XCTAssertEqual(article.score, 0.9)
    }

    func testPodcastDecodesFromJSON() throws {
        let json = """
        {
            "id": "pod1",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod1.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.id, "pod1")
        XCTAssertEqual(podcast.durationSeconds, 300)
        XCTAssertEqual(podcast.difficulty, "toeic_900")
    }

    func testPodcastFormattedDuration() throws {
        let podcast = Podcast(
            id: "pod1",
            type: "single",
            articleIds: ["abc123"],
            difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/pod1.mp3",
            title: "",
            japaneseIntroText: "今日のニュースは...",
            durationSeconds: 305,
            createdAt: "2026-05-31T06:00:00Z",
            status: "completed",
            errorMessage: nil,
            playbackPositionSeconds: 0.0,
            segments: nil
        )
        XCTAssertEqual(podcast.formattedDuration, "5:05")
    }

    func testPodcastDecodesStatusAndErrorMessage() throws {
        // 1. status:"failed" + error_message あり
        let failedJSON = """
        {
            "id": "pod-fail",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod-fail.mp3",
            "japanese_intro_text": "エラーが発生しました",
            "duration_seconds": 0,
            "created_at": "2026-06-25T00:00:00Z",
            "status": "failed",
            "error_message": "TTS failed"
        }
        """.data(using: .utf8)!

        let failedPodcast = try JSONDecoder().decode(Podcast.self, from: failedJSON)
        XCTAssertEqual(failedPodcast.status, "failed")
        XCTAssertEqual(failedPodcast.errorMessage, "TTS failed")

        // 2. status:"processing" + error_message キー無し
        let processingJSON = """
        {
            "id": "pod-proc",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod-proc.mp3",
            "japanese_intro_text": "処理中です",
            "duration_seconds": 0,
            "created_at": "2026-06-25T00:00:00Z",
            "status": "processing"
        }
        """.data(using: .utf8)!

        let processingPodcast = try JSONDecoder().decode(Podcast.self, from: processingJSON)
        XCTAssertEqual(processingPodcast.status, "processing")
        XCTAssertNil(processingPodcast.errorMessage)
    }

    func testFeedResponseDecodes() throws {
        let json = """
        {
            "articles": [],
            "date": "2026-05-31"
        }
        """.data(using: .utf8)!

        let feed = try JSONDecoder().decode(FeedResponse.self, from: json)
        XCTAssertEqual(feed.date, "2026-05-31")
        XCTAssertTrue(feed.articles.isEmpty)
    }

    // MARK: - IdentifiableURL（sheet(item:) 用ラッパー・FeedView/StarredView 共有）

    func testIdentifiableURLIdIsAbsoluteString() {
        let url = URL(string: "https://example.com/a")!
        let identifiable = IdentifiableURL(url: url)

        XCTAssertEqual(identifiable.id, url.absoluteString)
    }

    // MARK: - StarredArticlesResponse（GET /articles/starred・スタータブ）

    func testStarredArticlesResponseDecodesArticles() throws {
        let json = """
        {
            "articles": [
                {
                    "id": "abc123",
                    "title": "Rust is amazing",
                    "url": "https://example.com/rust",
                    "source": "hackernews",
                    "score": 0.9,
                    "published_at": "2026-05-31T06:00:00Z"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StarredArticlesResponse.self, from: json)
        XCTAssertEqual(response.articles.count, 1)
        XCTAssertEqual(response.articles[0].id, "abc123")
    }

    func testRssSourcesResponseDecodes() throws {
        let json = """
        {
            "sources": [
                {"name": "HackerNews", "url": "https://hnrss.org/frontpage"}
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RssSourcesResponse.self, from: json)
        XCTAssertEqual(response.sources.count, 1)
        XCTAssertEqual(response.sources[0].name, "HackerNews")
        // id は url から導出される
        XCTAssertEqual(response.sources[0].id, "https://hnrss.org/frontpage")
    }

    func testPreferencesDecodesFromJSON() throws {
        let json = """
        {
            "default_difficulty": "toeic_900",
            "default_playback_speed": 1.5
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(preferences.defaultDifficulty, "toeic_900")
        XCTAssertEqual(preferences.defaultPlaybackSpeed, 1.5)
    }

    func testPreferencesPartialFieldsDecodes() throws {
        let json = """
        {
            "default_difficulty": "ielts_55"
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(preferences.defaultDifficulty, "ielts_55")
        XCTAssertNil(preferences.defaultPlaybackSpeed)
    }

    // MARK: - GenerationQuota (issue #164 / ADR-061)

    func testGenerationQuotaDecodesFromJSON() throws {
        let json = """
        {
            "limit": 5,
            "used": 2,
            "remaining": 3,
            "reset_at": "2026-07-07T00:00:00Z"
        }
        """.data(using: .utf8)!

        let quota = try JSONDecoder().decode(GenerationQuota.self, from: json)

        XCTAssertEqual(quota.limit, 5)
        XCTAssertEqual(quota.used, 2)
        XCTAssertEqual(quota.remaining, 3)
        XCTAssertEqual(quota.resetAt, "2026-07-07T00:00:00Z")
    }

    func testGenerationQuotaDecodesUnlimitedWithNullRemaining() throws {
        // limit=0 は無制限を表し、remaining は null（ADR-061）。
        let json = """
        {
            "limit": 0,
            "used": 42,
            "remaining": null,
            "reset_at": "2026-07-07T00:00:00Z"
        }
        """.data(using: .utf8)!

        let quota = try JSONDecoder().decode(GenerationQuota.self, from: json)

        XCTAssertEqual(quota.limit, 0)
        XCTAssertNil(quota.remaining)
    }

    // MARK: - ListeningStreak (issue #165)

    func testListeningStreakDecodesFromJSON() throws {
        let json = """
        {
            "current_streak_days": 5,
            "today_listened": true,
            "last_listened_day": "2026-07-07"
        }
        """.data(using: .utf8)!

        let streak = try JSONDecoder().decode(ListeningStreak.self, from: json)

        XCTAssertEqual(streak.currentStreakDays, 5)
        XCTAssertTrue(streak.todayListened)
        XCTAssertEqual(streak.lastListenedDay, "2026-07-07")
    }

    func testListeningStreakDecodesNullLastListenedDay() throws {
        // 聴取歴が一度もない場合のみ last_listened_day は null になる。
        let json = """
        {
            "current_streak_days": 0,
            "today_listened": false,
            "last_listened_day": null
        }
        """.data(using: .utf8)!

        let streak = try JSONDecoder().decode(ListeningStreak.self, from: json)

        XCTAssertEqual(streak.currentStreakDays, 0)
        XCTAssertFalse(streak.todayListened)
        XCTAssertNil(streak.lastListenedDay)
    }

    func testListeningStreakDecodesZeroStreakWithPastListenedDay() throws {
        // backend の compute_streak（shared/streak.py）は、一昨日以前で連続が途切れた
        // 場合に current_streak_days=0 かつ last_listened_day=非null を返しうる
        // （test_gap_before_yesterday_resets_streak_to_zero で確認済み）。
        // 「0日 = 聴取歴なし」ではないことをここで固定する。
        let json = """
        {
            "current_streak_days": 0,
            "today_listened": false,
            "last_listened_day": "2026-07-03"
        }
        """.data(using: .utf8)!

        let streak = try JSONDecoder().decode(ListeningStreak.self, from: json)

        XCTAssertEqual(streak.currentStreakDays, 0)
        XCTAssertFalse(streak.todayListened)
        XCTAssertEqual(streak.lastListenedDay, "2026-07-03")
    }

    func testPodcastDecodesPlaybackPositionSeconds() throws {
        let json = """
        {
            "id": "pod-pos",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod-pos.mp3",
            "japanese_intro_text": "再生位置テスト",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "playback_position_seconds": 75.5
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.playbackPositionSeconds, 75.5)
    }

    func testPodcastPlaybackPositionSecondsDefaultsToZero() throws {
        let json = """
        {
            "id": "pod-nopos",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod-nopos.mp3",
            "japanese_intro_text": "デフォルトテスト",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.playbackPositionSeconds, 0.0)
    }

    // MARK: - Podcast.title フィールド（新規 API フィールド）

    /// APIレスポンスに "title" キーがあればデコードできる。
    func testPodcastDecodesTitleField() throws {
        let json = """
        {
            "id": "pod-title",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "title": "速報：重要なニュースです"
        }
        """.data(using: .utf8)!
        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.title, "速報：重要なニュースです")
    }

    /// APIレスポンスに "title" キーが無い（既存データ）場合は空文字になり、デコードが壊れない。
    func testPodcastTitleAbsentDefaultsToEmpty() throws {
        let json = """
        {
            "id": "pod-notitle",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!
        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.title, "")
    }

    // MARK: - Podcast.displayTitle（表示用タイトルのフォールバック）

    /// title が非空のときは displayTitle は title を返す。
    func testDisplayTitleUsesTitleFieldWhenPresent() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "速報タイトル",
            japaneseIntroText: "イントロテキスト",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        XCTAssertEqual(podcast.displayTitle, "速報タイトル")
    }

    /// title が空文字のときは displayTitle は japaneseIntroText にフォールバックする。
    func testDisplayTitleFallsBackToIntroWhenTitleEmpty() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "",
            japaneseIntroText: "イントロテキスト",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        XCTAssertEqual(podcast.displayTitle, "イントロテキスト")
    }

    /// title が空白のみのときも japaneseIntroText にフォールバックする。
    func testDisplayTitleFallsBackToIntroWhenTitleIsWhitespaceOnly() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "   ",
            japaneseIntroText: "イントロテキスト",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        XCTAssertEqual(podcast.displayTitle, "イントロテキスト")
    }

    /// title と japaneseIntroText の両方が空のとき、デフォルト文字列を返す（空欄にならない）。
    func testDisplayTitleFallsBackToDefaultWhenBothEmpty() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "",
            japaneseIntroText: "",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        XCTAssertEqual(podcast.displayTitle, "ニュースポッドキャスト")
    }

    // MARK: - Podcast.segments（トランスクリプト表示・issue #162）

    /// APIレスポンスに "segments" があれば話者・テキストの配列としてデコードできる。
    func testPodcastDecodesSegmentsField() throws {
        let json = """
        {
            "id": "pod-segments",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "segments": [
                {"speaker": "A", "text": "こんにちは。"},
                {"speaker": "B", "text": "今日のニュースです。"}
            ]
        }
        """.data(using: .utf8)!
        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.segments, [
            TranscriptSegment(speaker: "A", text: "こんにちは。"),
            TranscriptSegment(speaker: "B", text: "今日のニュースです。"),
        ])
    }

    /// 旧エピソードなど "segments" キーが無い場合は nil になり、他フィールドのデコードは壊れない。
    func testPodcastSegmentsAbsentDefaultsToNil() throws {
        let json = """
        {
            "id": "pod-nosegments",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!
        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertNil(podcast.segments)
        XCTAssertEqual(podcast.durationSeconds, 300)
        XCTAssertEqual(podcast.status, "completed")
    }

    /// "segments" キーが null（JSON null）の場合も nil としてデコードできる。
    func testPodcastSegmentsNullDefaultsToNil() throws {
        let json = """
        {
            "id": "pod-nullsegments",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "segments": null
        }
        """.data(using: .utf8)!
        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertNil(podcast.segments)
    }

    /// TranscriptSegment は Equatable。speaker/text が両方一致すれば等価。
    func testTranscriptSegmentEquatable() {
        let a = TranscriptSegment(speaker: "A", text: "同じ内容")
        let b = TranscriptSegment(speaker: "A", text: "同じ内容")
        let c = TranscriptSegment(speaker: "B", text: "同じ内容")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - TranscriptSegment.role（ADR-094 第一段階・Issue #237）
    //
    // WHY: 正本 backend/shared/models.py の TranscriptSegment.role（fact|commentary|null）に
    // 合わせ、iOS 側にも省略可フィールドとして role を追加済み。以下は present/absent/null の
    // 3 経路のデコード契約を固定する回帰テスト群。

    /// "role" キーが含まれる segment を "fact"/"commentary" としてデコードできること。
    func testTranscriptSegmentDecodesRoleWhenPresent() throws {
        let json = """
        {"speaker": "A", "text": "Rust is fast.", "role": "fact"}
        """.data(using: .utf8)!
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
        XCTAssertEqual(segment.role, "fact")
    }

    /// "role" キーが無い（旧エピソード）場合は nil にデコードされること。
    func testTranscriptSegmentRoleAbsentDefaultsToNil() throws {
        let json = """
        {"speaker": "A", "text": "Rust is fast."}
        """.data(using: .utf8)!
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
        XCTAssertNil(segment.role)
    }

    /// "role" が JSON null の場合も nil にデコードされること。
    func testTranscriptSegmentRoleNullDefaultsToNil() throws {
        let json = """
        {"speaker": "A", "text": "Rust is fast.", "role": null}
        """.data(using: .utf8)!
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
        XCTAssertNil(segment.role)
    }

    // MARK: - Podcast.hasTranscript（AudioPlayerView の折りたたみ表示可否・issue #162）

    /// segments が非空配列を持つ場合、hasTranscript は true を返す。
    func testHasTranscriptTrueWhenSegmentsNonEmpty() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: [TranscriptSegment(speaker: "A", text: "こんにちは")]
        )
        XCTAssertTrue(podcast.hasTranscript)
    }

    /// segments が nil の場合、hasTranscript は false を返す（旧エピソード・グレースフルデグレード）。
    func testHasTranscriptFalseWhenSegmentsNil() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil
        )
        XCTAssertFalse(podcast.hasTranscript)
    }

    /// segments が空配列の場合も、表示すべき内容が無いため hasTranscript は false を返す。
    func testHasTranscriptFalseWhenSegmentsEmpty() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: []
        )
        XCTAssertFalse(podcast.hasTranscript)
    }

    // MARK: - Podcast vocabulary / quiz（ADR-069 / ADR-070）

    func testPodcastDecodesVocabularyAndPublicQuiz() throws {
        let json = """
        {
            "id": "pod-learning",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-07-29T00:00:00Z",
            "status": "completed",
            "vocabulary": [
                {
                    "term": "containerization",
                    "meaning_ja": "アプリケーションを独立した単位で実行する技術",
                    "example": "Containerization changed application deployment."
                }
            ],
            "quiz": [
                {
                    "question": "What changed application deployment?",
                    "options": ["Containerization", "Paper", "Ink", "Audio"]
                }
            ]
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)

        XCTAssertEqual(
            podcast.vocabulary,
            [VocabularyEntry(
                term: "containerization",
                meaningJa: "アプリケーションを独立した単位で実行する技術",
                example: "Containerization changed application deployment."
            )]
        )
        XCTAssertEqual(
            podcast.quiz,
            [QuizQuestion(
                question: "What changed application deployment?",
                options: ["Containerization", "Paper", "Ink", "Audio"]
            )]
        )
        XCTAssertTrue(podcast.hasVocabulary)
        XCTAssertTrue(podcast.hasQuiz)
    }

    func testPodcastDecodesNullVocabularyAndQuizAsNil() throws {
        let json = """
        {
            "id": "pod-null-learning",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-07-29T00:00:00Z",
            "status": "completed",
            "vocabulary": null,
            "quiz": null
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)

        XCTAssertNil(podcast.vocabulary)
        XCTAssertNil(podcast.quiz)
        XCTAssertFalse(podcast.hasVocabulary)
        XCTAssertFalse(podcast.hasQuiz)
    }

    func testPodcastMissingVocabularyAndQuizKeysDegradesGracefully() throws {
        let json = """
        {
            "id": "pod-old",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "旧エピソード",
            "duration_seconds": 300,
            "created_at": "2026-07-29T00:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)

        XCTAssertNil(podcast.vocabulary)
        XCTAssertNil(podcast.quiz)
    }

    // MARK: - Podcast.sourceArticles / Podcast.sourceKind（ADR-095 / issue #240）
    //
    // WHY: ADR-095 は一律 CC BY-SA 4.0 表示を featured 由来の生成物に限定する。
    // source_kind == "featured" のときだけライセンス表示を出す判定を、デコードと
    // 純computed propertyでここに固定する。

    /// "source_articles"（2件）と "source_kind":"featured" を含むレスポンスをデコードできる。
    func testPodcastDecodesSourceArticlesAndSourceKind() throws {
        let json = """
        {
            "id": "pod-source",
            "type": "single",
            "article_ids": ["abc123", "def456"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "source_articles": [
                {"article_id": "abc123", "title": "Rust is amazing", "url": "https://example.com/rust", "source": "hackernews"},
                {"article_id": "def456", "title": "Swift 6 released", "url": "https://example.com/swift6", "source": "techcrunch"}
            ],
            "source_kind": "featured"
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)

        XCTAssertEqual(podcast.sourceArticles, [
            PodcastSourceArticle(articleId: "abc123", title: "Rust is amazing", url: "https://example.com/rust", source: "hackernews"),
            PodcastSourceArticle(articleId: "def456", title: "Swift 6 released", url: "https://example.com/swift6", source: "techcrunch"),
        ])
        XCTAssertEqual(podcast.sourceKind, "featured")
    }

    /// "source_articles" / "source_kind" のキーが無い（旧エピソード）場合は nil になり、他フィールドは無傷。
    func testPodcastSourceArticlesAbsentDefaultsToNil() throws {
        let json = """
        {
            "id": "pod-nosource",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)

        XCTAssertNil(podcast.sourceArticles)
        XCTAssertNil(podcast.sourceKind)
        XCTAssertEqual(podcast.durationSeconds, 300)
        XCTAssertEqual(podcast.status, "completed")
    }

    /// "source_articles" / "source_kind" が JSON null の場合も nil としてデコードできる。
    func testPodcastSourceArticlesNullDefaultsToNil() throws {
        let json = """
        {
            "id": "pod-nullsource",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "source_articles": null,
            "source_kind": null
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)

        XCTAssertNil(podcast.sourceArticles)
        XCTAssertNil(podcast.sourceKind)
    }

    /// source_articles 要素に必須キー（url）が欠落している場合、Podcast 全体のデコードが失敗する
    /// （VocabularyEntry / QuizQuestion と同じく部分救済はしない）。
    func testPodcastSourceArticleMissingRequiredKeyFailsDecoding() {
        let json = """
        {
            "id": "pod-badsource",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z",
            "status": "completed",
            "source_articles": [
                {"article_id": "abc123", "title": "Rust is amazing", "source": "hackernews"}
            ]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(Podcast.self, from: json))
    }

    // MARK: - Podcast.hasSourceArticles（出典セクション表示可否・issue #240）

    /// sourceArticles が非空配列を持つ場合、hasSourceArticles は true を返す。
    func testHasSourceArticlesTrueWhenNonEmpty() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceArticles: [PodcastSourceArticle(articleId: "a1", title: "t", url: "https://example.com", source: "s")]
        )
        XCTAssertTrue(podcast.hasSourceArticles)
    }

    /// sourceArticles が nil（省略）の場合、hasSourceArticles は false を返す。
    func testHasSourceArticlesFalseWhenNil() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil
        )
        XCTAssertFalse(podcast.hasSourceArticles)
    }

    /// sourceArticles が空配列の場合も、表示すべき内容が無いため hasSourceArticles は false を返す。
    func testHasSourceArticlesFalseWhenEmpty() {
        let podcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceArticles: []
        )
        XCTAssertFalse(podcast.hasSourceArticles)
    }

    /// featured 由来なら source_articles が欠落・null・空配列でも、出典一覧は出さず
    /// CC BY-SA 4.0 の帰属表示だけを維持する（issue #240）。
    func testFeaturedPodcastWithoutSourceArticlesStillShowsLicenseNotice() throws {
        let sourceArticlesValues = [
            "missing": "",
            "null": "\"source_articles\": null,",
            "empty": "\"source_articles\": [],"
        ]

        for (caseName, sourceArticles) in sourceArticlesValues {
            let json = """
            {
                "id": "pod-\(caseName)",
                "type": "single",
                "article_ids": [],
                "difficulty": "toeic_900",
                "audio_url": "https://storage.example.com/pod.mp3",
                "japanese_intro_text": "イントロ",
                "duration_seconds": 300,
                "created_at": "2026-05-31T06:00:00Z",
                "status": "completed",
                \(sourceArticles)
                "source_kind": "featured"
            }
            """.data(using: .utf8)!

            let podcast = try JSONDecoder().decode(Podcast.self, from: json)
            let content = PodcastAttributionContent(podcast: podcast)

            XCTAssertFalse(content.showsSourceArticleList, "case=\(caseName)")
            XCTAssertEqual(
                content.licenseNotice.map { String($0.characters) },
                Podcast.ccBySaLicenseNoticePlainText,
                "case=\(caseName)"
            )
        }
    }

    // MARK: - Podcast.showsCcBySaLicense（ADR-095 fail-closed 判定・issue #240）

    /// sourceKind == "featured" のときだけ true。"user"/"unknown"/nil/大文字違い/空文字は false
    /// （fail-closed、完全一致。trim / lowercased は行わない）。
    func testShowsCcBySaLicenseTrueOnlyForFeatured() {
        let featuredPodcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceKind: "featured"
        )
        let userPodcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceKind: "user"
        )
        let unknownPodcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceKind: "unknown"
        )
        let nilKindPodcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil
        )
        let capitalizedPodcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceKind: "Featured"
        )
        let emptyKindPodcast = Podcast(
            id: "p1", type: "daily", articleIds: [],
            difficulty: "toeic_900", audioUrl: "",
            title: "", japaneseIntroText: "イントロ",
            durationSeconds: 0, createdAt: "", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: nil,
            sourceKind: ""
        )

        XCTAssertTrue(featuredPodcast.showsCcBySaLicense)
        XCTAssertFalse(userPodcast.showsCcBySaLicense)
        XCTAssertFalse(unknownPodcast.showsCcBySaLicense)
        XCTAssertFalse(nilKindPodcast.showsCcBySaLicense)
        XCTAssertFalse(capitalizedPodcast.showsCcBySaLicense)
        XCTAssertFalse(emptyKindPodcast.showsCcBySaLicense)
    }

    // MARK: - PodcastSourceArticle.linkURL（スキーム検証・issue #240）

    /// http / https（大文字小文字を問わない）は linkURL が非 nil。
    func testPodcastSourceArticleLinkURLAcceptsHttpAndHttps() {
        let httpsArticle = PodcastSourceArticle(articleId: "a1", title: "t", url: "https://example.com/a", source: "s")
        let httpArticle = PodcastSourceArticle(articleId: "a2", title: "t", url: "http://example.com/b", source: "s")
        let upperCaseSchemeArticle = PodcastSourceArticle(articleId: "a3", title: "t", url: "HTTPS://example.com/c", source: "s")

        XCTAssertNotNil(httpsArticle.linkURL)
        XCTAssertNotNil(httpArticle.linkURL)
        XCTAssertNotNil(upperCaseSchemeArticle.linkURL)
    }

    /// http(s) 以外のスキーム・不正な文字列は linkURL が nil
    /// （バックエンド経由の外部由来文字列を無検証で openURL に渡さない）。
    func testPodcastSourceArticleLinkURLRejectsNonWebSchemesAndInvalid() {
        let cases = ["javascript:alert(1)", "tel:000", "", "not a url", "/relative"]
        for url in cases {
            let article = PodcastSourceArticle(articleId: "a1", title: "t", url: url, source: "s")
            XCTAssertNil(article.linkURL, "url=\(url) は linkURL が nil であるべき")
        }
    }

    // MARK: - Podcast.ccBySaLicenseNotice（ADR-095 ライセンス文・issue #240）

    /// Markdown 記法を除去したプレーンテキストが web と同一文言と一致する
    /// （Markdown 記法が文字として残っていないことも含意する）。
    func testCcBySaLicenseNoticePlainTextMatchesWebCopy() {
        let plain = String(Podcast.ccBySaLicenseNotice.characters)
        XCTAssertEqual(plain, Podcast.ccBySaLicenseNoticePlainText)
        XCTAssertEqual(plain, "この音声コンテンツは CC BY-SA 4.0 で提供されます。")
    }

    /// リンク属性を持つ run はちょうど1つで、"CC BY-SA 4.0" 部分だけに
    /// ADR-095 のライセンス URL が付与される（`Text(String)` の verbatim 描画では
    /// この属性自体が存在しない）。
    func testCcBySaLicenseNoticeLinksOnlyLicenseName() throws {
        let notice = Podcast.ccBySaLicenseNotice
        let linkRuns = notice.runs.filter { $0.link != nil }

        XCTAssertEqual(linkRuns.count, 1)
        let run = try XCTUnwrap(linkRuns.first)
        XCTAssertEqual(run.link, URL(string: "https://creativecommons.org/licenses/by-sa/4.0/deed.ja"))
        XCTAssertEqual(String(notice[run.range].characters), "CC BY-SA 4.0")
    }

    func testQuizAnswerResponseDecodesBackendContract() throws {
        let json = """
        {
            "correct_count": 2,
            "total": 3,
            "correct_rate": 0.6666666667,
            "results": [
                {
                    "question_index": 0,
                    "selected_index": 1,
                    "correct_index": 1,
                    "is_correct": true
                },
                {
                    "question_index": 1,
                    "selected_index": 0,
                    "correct_index": 2,
                    "is_correct": false
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(QuizAnswerResponse.self, from: json)

        XCTAssertEqual(response.correctCount, 2)
        XCTAssertEqual(response.total, 3)
        XCTAssertEqual(response.correctRate, 0.6666666667, accuracy: 0.0000001)
        XCTAssertEqual(response.results[0].questionIndex, 0)
        XCTAssertTrue(response.results[0].isCorrect)
        XCTAssertEqual(response.results[1].correctIndex, 2)
        XCTAssertFalse(response.results[1].isCorrect)
    }
}
