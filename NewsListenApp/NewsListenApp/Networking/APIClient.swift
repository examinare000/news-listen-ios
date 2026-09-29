//
//  APIClient.swift
//  NewsListenApp
//
//  URLSession ベースの API クライアント。X-API-Key ヘッダ付与・JSON デコード・
//  HTTP ステータス検証を一元化する。テスト用に URLSessionProtocol で注入可能にする。
//

import Foundation

/// `URLSession` を差し替え可能にしてテストでモックを注入するための抽象。
protocol URLSessionProtocol {
    /// 指定リクエストを実行し、レスポンスボディとメタデータを返す。
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

/// 宣言のある 404 が指す対象（意味の無い 404 と区別する。Spec §2.1 D3）。
///
/// - `streak` / `quota` / `quiz`: 旧 backend または機能未提供。
/// - `credential` / `session` / `star`: 冪等削除・冪等失効が既に完了している。
enum NotFoundSubject: Equatable {
    case streak, quota, quiz
    case credential, session, star
}

/// API 通信の失敗を表す値（Spec §2.1）。値集合はここに列挙した 10 case のみで、追加しない。
///
/// `LocalizedError` には適合させない。適合させると `localizedDescription` 経由で文言を得る経路が
/// 残り、文言の所有者が `FailureMessages` 1 箇所に定まらなくなる（order 完了条件 5）。
enum ApiFailure: Error, Equatable {
    case network(URLError)
    case unauthorized
    case forbidden
    case notFound(subject: NotFoundSubject)
    case conflict
    case rateLimited(retryAfter: Int?)
    case validation
    case server(status: Int)
    case decoding
    case unknown(status: Int)
}

/// バックエンド API への通信を担うクライアント。
///
/// `X-API-Key` ヘッダの付与、JSON デコード、HTTP ステータス検証を一元化する。
///
/// - Note: ObservableObject には適合しない。`@Published` な状態を持たず、ビューから直接
///   購読されることもない（常に ViewModel に内包されるか `AppState` 経由で参照される）ため不要。
@MainActor
final class APIClient {
    /// API のベース URL。各エンドポイントのパスを連結して使う。
    private let baseURL: URL
    /// `X-API-Key` ヘッダに付与する API キー（ゲートウェイ認証）。
    private let apiKey: String
    /// セッショントークン。設定時は `Authorization: Bearer` でユーザー認証に使う。
    private let sessionToken: String?
    /// 実通信を行うセッション。テスト時はモックを注入する。
    private let session: URLSessionProtocol
    /// レスポンスボディのデコードに使う JSON デコーダ。
    private let decoder: JSONDecoder
    /// Authorization 付きリクエストが 401 を受けたときに 1 回呼ばれる observer（I-S2 / CI-T14.8）。
    /// HTTP status・トークンは渡さない（境界の leakage 検査: spec §4）。
    private let onUnauthorized: (@MainActor () -> Void)?

    /// クライアントを生成する。
    /// - Parameters:
    ///   - baseURL: API のベース URL。
    ///   - apiKey: `X-API-Key` ヘッダに付与する API キー。
    ///   - sessionToken: ユーザー認証用のセッショントークン（未ログイン時は `nil`）。
    ///   - session: 通信に使うセッション。既定は `URLSession.shared`。
    ///   - onUnauthorized: Authorization 付きリクエストが 401 を受けたときに 1 回呼ばれる observer。
    init(
        baseURL: URL,
        apiKey: String,
        sessionToken: String? = nil,
        session: URLSessionProtocol = URLSession.shared,
        onUnauthorized: (@MainActor () -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionToken = sessionToken
        self.session = session
        self.decoder = JSONDecoder()
        self.onUnauthorized = onUnauthorized
    }

    // MARK: - Feed

    /// フィードの記事一覧を取得する。
    func fetchFeed() async throws -> FeedResponse {
        try await request(.feed, responseType: FeedResponse.self)
    }

    /// Star 済み記事一覧を取得する（スタータブ）。
    func fetchStarredArticles() async throws -> StarredArticlesResponse {
        try await request(.starredArticles, responseType: StarredArticlesResponse.self)
    }

    /// 指定 ID の記事を Star する。
    /// - Parameters:
    ///   - id: 対象記事の ID。
    ///   - difficulty: 記事単位で指定する難易度（issue #163）。`nil` なら従来どおりボディなしで送り、
    ///     生成は prefs のデフォルト難易度に委ねる。
    func starArticle(id: String, difficulty: String? = nil) async throws {
        let body: [String: Any]? = difficulty.map { ["difficulty": $0] }
        try await requestVoid(.starArticle(id: id), body: body)
    }

    /// 指定 ID の記事の Star を解除する（スタータブのスワイプ導線）。
    ///
    /// backend は冪等（記事 doc が既に存在しない場合のみ 404）で、生成済み Podcast も削除される。
    /// - Parameter id: 対象記事の ID。
    func unstarArticle(id: String) async throws {
        try await requestVoid(.unstarArticle(id: id), notFoundSubject: .star)
    }

    /// 指定 ID の記事を Dismiss する。
    /// - Parameter id: 対象記事の ID。
    func dismissArticle(id: String) async throws {
        try await requestVoid(.dismissArticle(id: id))
    }

    // MARK: - Podcasts

    /// Podcast 一覧を取得する。
    func fetchPodcasts() async throws -> PodcastListResponse {
        try await request(.podcasts, responseType: PodcastListResponse.self)
    }

    /// 指定 ID の Podcast を取得する（オフライン再生時の署名付き URL 再取得用）。
    /// - Parameter id: 対象 Podcast の ID。
    func fetchPodcast(id: String) async throws -> Podcast {
        try await request(.podcast(id: id), responseType: Podcast.self)
    }

    /// 指定 Podcast の再生位置を更新する。
    /// - Parameters:
    ///   - podcastId: 対象 Podcast の ID。
    ///   - positionSeconds: 再生位置（秒）。
    /// - Returns: 更新後の Podcast 情報。
    func updatePlaybackPosition(podcastId: String, positionSeconds: Double) async throws -> Podcast {
        let body = ["position_seconds": positionSeconds]
        return try await request(.updatePlaybackPosition(id: podcastId), body: body, responseType: Podcast.self)
    }

    /// Podcast の自然終端到達を記録する。リクエストボディは送らない。
    func markCompleted(id: String) async throws {
        try await requestVoid(.markCompleted(podcastId: id))
    }

    /// 理解度クイズの選択肢添字を送信し、サーバー採点結果を取得する。
    func submitQuizAnswers(podcastId: String, answers: [Int]) async throws -> QuizAnswerResponse {
        try await request(
            .submitQuizAnswers(podcastId: podcastId),
            body: ["answers": answers],
            notFoundSubject: .quiz,
            responseType: QuizAnswerResponse.self
        )
    }

    /// 指定 URL から音声データをダウンロードする。
    ///
    /// **セキュリティ**: 外部署名 URL（GCS 等）に対してヘッダを付けない。
    /// X-API-Key・Authorization は付与せず、URLRequest をそのまま実行する。
    /// - Parameter url: 音声ファイルの URL。
    /// - Returns: 音声データ。
    func downloadAudio(from url: URL) async throws -> Data {
        let request = URLRequest(url: url)
        return try await performData(request)
    }

    // MARK: - Settings

    /// ユーザー設定選択（難易度・再生速度）を取得する。
    func fetchPreferences() async throws -> Preferences {
        try await request(.preferences, responseType: Preferences.self)
    }

    /// ユーザー設定選択を更新する。指定した項目のみ送る。
    /// - Parameters:
    ///   - defaultDifficulty: 新しい既定難易度（任意）。
    ///   - defaultPlaybackSpeed: 新しい既定再生速度（任意）。
    /// - Returns: 更新後の設定選択。
    func updatePreferences(
        defaultDifficulty: String?,
        defaultPlaybackSpeed: Double?,
        weeklyGoalEpisodes: Int? = nil
    ) async throws -> Preferences {
        var body: [String: Any] = [:]
        if let defaultDifficulty { body["default_difficulty"] = defaultDifficulty }
        if let defaultPlaybackSpeed { body["default_playback_speed"] = defaultPlaybackSpeed }
        if let weeklyGoalEpisodes { body["weekly_goal_episodes"] = weeklyGoalEpisodes }
        return try await request(.updatePreferences, body: body, responseType: Preferences.self)
    }

    /// Podcast 生成の本日残回数を取得する（issue #164 / ADR-061）。
    func fetchGenerationQuota() async throws -> GenerationQuota {
        try await request(.generationQuota, notFoundSubject: .quota, responseType: GenerationQuota.self)
    }

    /// 聴取ストリーク（連続聴取日数）を取得する（issue #165）。
    func fetchListeningStreak() async throws -> ListeningStreak {
        try await request(.listeningStreak, notFoundSubject: .streak, responseType: ListeningStreak.self)
    }

    // MARK: - Learning engagement

    func fetchLearningDashboard() async throws -> LearningDashboard {
        try await request(.learningDashboard, responseType: LearningDashboard.self)
    }

    func saveVocabulary(podcastId: String, term: String) async throws -> VocabularyItem {
        try await request(
            .saveVocabulary,
            body: ["podcast_id": podcastId, "term": term],
            responseType: VocabularyItem.self
        )
    }

    func fetchVocabulary() async throws -> VocabularyListResponse {
        try await request(.vocabulary, responseType: VocabularyListResponse.self)
    }

    func deleteVocabulary(id: String) async throws -> DeleteVocabularyResponse {
        try await request(.deleteVocabulary(id: id), responseType: DeleteVocabularyResponse.self)
    }

    func fetchVocabularyTestSession() async throws -> VocabularyTestSessionResponse {
        try await request(.vocabularyTestSession, responseType: VocabularyTestSessionResponse.self)
    }

    func submitVocabularyTestResult(
        _ items: [VocabularyTestResultItem]
    ) async throws -> VocabularyTestResultResponse {
        let body: [[String: Any]] = items.map {
            [
                "vocabulary_id": $0.vocabularyId,
                "self_known": $0.selfKnown,
                "retest_correct": $0.retestCorrect ?? NSNull(),
            ]
        }
        return try await request(
            .submitVocabularyTestResult,
            body: body,
            responseType: VocabularyTestResultResponse.self
        )
    }

    /// 登録済みの RSS 配信元一覧を取得する。
    func fetchSources() async throws -> RssSourcesResponse {
        try await request(.sources, responseType: RssSourcesResponse.self)
    }

    /// RSS 配信元を追加し、更新後の一覧を返す。
    /// - Parameters:
    ///   - name: 配信元の表示名。
    ///   - url: RSS フィードの URL。
    /// - Returns: 追加後の RSS 配信元一覧。
    func addSource(name: String, url: String) async throws -> RssSourcesResponse {
        let body = ["name": name, "url": url]
        return try await request(.addSource, body: body, responseType: RssSourcesResponse.self)
    }

    /// 既存 RSS 配信元の名称・URL を更新し、更新後の一覧を返す（issue #112）。
    /// - Parameters:
    ///   - oldURL: 更新対象を特定する既存の RSS フィード URL。
    ///   - name: 新しい表示名。
    ///   - url: 新しい RSS フィード URL（変更しない場合は `oldURL` と同値を渡す）。
    /// - Returns: 更新後の RSS 配信元一覧。
    func updateSource(oldURL: String, name: String, url: String) async throws -> RssSourcesResponse {
        let body = ["old_url": oldURL, "name": name, "url": url]
        return try await request(.updateSource, body: body, responseType: RssSourcesResponse.self)
    }

    /// 指定 URL の RSS 配信元を削除する。
    /// - Parameter url: 削除対象の RSS フィード URL。
    func removeSource(url: String) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(APIEndpoint.removeSource(url: url).path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        _ = try await performData(req)
    }

    // MARK: - Push（APNs デバイストークン）

    /// iOS APNs デバイストークンを登録する（Bearer 要・冪等）。
    /// - Parameter token: APNs デバイストークン（16 進文字列）。
    func registerDeviceToken(_ token: String) async throws {
        try await requestVoid(.registerDeviceToken, body: ["device_token": token])
    }

    /// iOS APNs デバイストークンを解除する（Bearer 要・冪等）。
    ///
    /// token はクエリパラメータで渡す（既存 `removeSource` と同じ規約）。
    /// - Parameter token: 解除する APNs デバイストークン。
    func unregisterDeviceToken(_ token: String) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(APIEndpoint.unregisterDeviceToken.path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        _ = try await performData(req)
    }

    // MARK: - Auth（セッション）

    /// ログインしてセッショントークンとユーザー情報を取得する。
    /// - Parameters:
    ///   - username: ログイン ID。
    ///   - password: パスワード。
    func login(username: String, password: String) async throws -> LoginResponse {
        try await request(
            .login,
            body: ["username": username, "password": password],
            responseType: LoginResponse.self
        )
    }

    /// ログアウトしてサーバ側セッションを破棄する。
    func logout() async throws {
        try await requestVoid(.logout)
    }

    /// ログイン中ユーザー情報を取得する。
    func fetchMe() async throws -> AuthUser {
        try await request(.me, responseType: AuthUser.self)
    }

    /// 自分の表示名を更新する。
    /// - Parameter displayName: 新しい表示名。
    func updateProfile(displayName: String) async throws -> AuthUser {
        try await request(.updateProfile, body: ["display_name": displayName], responseType: AuthUser.self)
    }

    /// 自分のパスワードを変更する。
    /// - Parameters:
    ///   - current: 現在のパスワード。
    ///   - new: 新しいパスワード。
    func changePassword(current: String, new: String) async throws {
        try await requestVoid(.changePassword, body: ["current_password": current, "new_password": new])
    }

    // MARK: - Admin（ユーザー管理）

    /// ユーザー一覧を取得する（管理者）。
    func listUsers() async throws -> UserListResponse {
        try await request(.listUsers, responseType: UserListResponse.self)
    }

    /// ユーザーを新規作成する（管理者）。
    func createUser(
        username: String,
        password: String,
        displayName: String?,
        role: String
    ) async throws -> AuthUser {
        var body: [String: Any] = ["username": username, "password": password, "role": role]
        if let displayName, !displayName.isEmpty { body["display_name"] = displayName }
        return try await request(.createUser, body: body, responseType: AuthUser.self)
    }

    /// ユーザーを更新する（管理者）。指定した項目のみ送る。
    func updateUser(
        username: String,
        role: String? = nil,
        newPassword: String? = nil,
        displayName: String? = nil
    ) async throws -> AuthUser {
        var body: [String: Any] = [:]
        if let role { body["role"] = role }
        if let newPassword { body["new_password"] = newPassword }
        if let displayName { body["display_name"] = displayName }
        return try await request(.updateUser(username: username), body: body, responseType: AuthUser.self)
    }

    /// ユーザーを削除する（管理者）。
    /// - Parameter username: 削除対象のユーザー ID。
    func deleteUser(username: String) async throws {
        try await requestVoid(.deleteUser(username: username))
    }

    // MARK: - Featured sites / Onboarding

    /// システム提供のおすすめサイト一覧を取得する（order 昇順）。
    func fetchFeaturedSites() async throws -> FeaturedSitesResponse {
        try await request(.featuredSources, responseType: FeaturedSitesResponse.self)
    }

    /// 初回オンボーディングの完了状態を取得する。
    func fetchOnboardingStatus() async throws -> OnboardingStatusResponse {
        try await request(.onboardingStatus, responseType: OnboardingStatusResponse.self)
    }

    /// 初回オンボーディング完了を記録し、更新後の状態を返す。
    func completeOnboarding() async throws -> OnboardingStatusResponse {
        try await request(.completeOnboarding, responseType: OnboardingStatusResponse.self)
    }

    // MARK: - Passkey（WebAuthn）

    /// Passkey 登録オプションを取得する（Bearer 要）。
    func passkeyRegisterOptions() async throws -> PasskeyOptionsAPIResponse {
        try await request(.passkeyRegisterOptions, responseType: PasskeyOptionsAPIResponse.self)
    }

    /// Passkey 登録クレデンシャルをサーバに送り検証・保存する（Bearer 要）。
    ///
    /// - Parameters:
    ///   - challengeID: options 取得時に受領したチャレンジ相関 ID。
    ///   - credential: `PasskeyCredentialEncoder.encodeRegistration` が返した dict。
    func passkeyRegisterVerify(challengeID: String, credential: [String: Any]) async throws {
        let body: [String: Any] = ["challenge_id": challengeID, "credential": credential]
        try await requestVoid(.passkeyRegisterVerify, body: body)
    }

    /// Passkey 認証オプションを取得する（認証不要・CSRF 免除・body: {}）。
    ///
    /// バックエンド契約: allowCredentials は常に空（discoverable / usernameless フロー）。
    func passkeyLoginOptions() async throws -> PasskeyOptionsAPIResponse {
        // login/options は認証不要だが、iOS は Bearer を付けても問題なし（CSRF 免除）。
        // body: {} を明示的に送る（バックエンドは PasskeyLoginOptionsRequest で {} を受け付ける）。
        let emptyBody: [String: Any] = [:]
        return try await request(.passkeyLoginOptions, body: emptyBody, responseType: PasskeyOptionsAPIResponse.self)
    }

    /// Passkey 認証クレデンシャルをサーバに送り検証・セッション発行する（認証不要）。
    ///
    /// - Parameters:
    ///   - challengeID: options 取得時に受領したチャレンジ相関 ID。
    ///   - credential: `PasskeyCredentialEncoder.encodeAssertion` が返した dict。
    /// - Returns: `LoginResponse`（token + user）。
    func passkeyLoginVerify(challengeID: String, credential: [String: Any]) async throws -> LoginResponse {
        let body: [String: Any] = ["challenge_id": challengeID, "credential": credential]
        return try await request(.passkeyLoginVerify, body: body, responseType: LoginResponse.self)
    }

    /// 登録済み Passkey クレデンシャル一覧を取得する（Bearer 要）。
    func listPasskeyCredentials() async throws -> PasskeyCredentialsAPIResponse {
        try await request(.passkeyCredentials, responseType: PasskeyCredentialsAPIResponse.self)
    }

    /// 指定 credential ID の Passkey を削除する（Bearer 要・冪等）。
    ///
    /// - Parameter id: 削除対象のクレデンシャル ID（base64url 文字列）。
    func deletePasskeyCredential(id: String) async throws {
        try await requestVoid(.passkeyDeleteCredential(id: id), notFoundSubject: .credential)
    }

    /// 自分の有効セッション（ログイン中デバイス）一覧を取得する（Bearer 要・issue #84）。
    func listSessions() async throws -> SessionsAPIResponse {
        try await request(.sessions, responseType: SessionsAPIResponse.self)
    }

    /// 指定セッションを個別失効する（Bearer 要・他人/不在は 404・冪等）。
    func revokeSession(id: String) async throws {
        try await requestVoid(.revokeSession(id: id), notFoundSubject: .session)
    }

    /// 現在以外のセッションを一括失効する（「他のデバイスからログアウト」）。
    func revokeOtherSessions() async throws -> RevokeSessionsAPIResponse {
        try await request(.revokeOtherSessions, body: [:], responseType: RevokeSessionsAPIResponse.self)
    }

    /// クライアントのエラー/クラッシュを backend へ報告する（issue #83・認証不要・X-API-Key のみ）。
    func reportClientError(_ payload: ClientErrorPayload) async throws {
        var body: [String: Any] = ["source": payload.source, "kind": payload.kind]
        if let message = payload.message { body["message"] = message }
        if let context = payload.context { body["context"] = context }
        try await requestVoid(.clientErrors, body: body)
    }

    // MARK: - Private helpers

    /// エンドポイントへリクエストを送り、レスポンスを指定型へデコードして返す。
    /// - Parameters:
    ///   - endpoint: 対象エンドポイント。
    ///   - body: 送信する JSON ボディ（任意）。
    ///   - notFoundSubject: 404 が意味を持つ endpoint のときだけ渡す（D3）。
    ///   - responseType: デコード先の型。
    private func request<T: Decodable>(
        _ endpoint: APIEndpoint,
        body: Any? = nil,
        notFoundSubject: NotFoundSubject? = nil,
        responseType: T.Type
    ) async throws -> T {
        let req = try buildRequest(endpoint, body: body)
        let data = try await performData(req, notFoundSubject: notFoundSubject)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ApiFailure.decoding
        }
    }

    /// レスポンスボディを必要としないリクエストを送り、ステータス検証のみ行う。
    /// - Parameters:
    ///   - endpoint: 対象エンドポイント。
    ///   - body: 送信する JSON ボディ（任意）。
    ///   - notFoundSubject: 404 が意味を持つ endpoint のときだけ渡す（D3）。
    private func requestVoid(
        _ endpoint: APIEndpoint,
        body: [String: Any]? = nil,
        notFoundSubject: NotFoundSubject? = nil
    ) async throws {
        let req = try buildRequest(endpoint, body: body)
        _ = try await performData(req, notFoundSubject: notFoundSubject)
    }

    /// エンドポイントと任意のボディから、API キー付きの `URLRequest` を組み立てる。
    /// - Parameters:
    ///   - endpoint: 対象エンドポイント。
    ///   - body: JSON 化して送信するボディ（任意）。
    ///
    /// `JSONSerialization` の失敗は `session.data(for:)` より前に起きるプログラミングエラーとして
    /// 扱い、`ApiFailure` には写像しない（D1 の明示的な例外）。
    private func buildRequest(_ endpoint: APIEndpoint, body: Any?) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint.path)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        // セッショントークンがあればユーザー認証ヘッダを付与する（Web は Cookie、iOS は Bearer）。
        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// 通信を実行し、transport の失敗を `ApiFailure` へ写像してからレスポンスを検証する（D1・D2）。
    /// - Parameters:
    ///   - request: 実行する `URLRequest`。
    ///   - notFoundSubject: 404 が意味を持つ endpoint のときだけ渡す（D3）。
    /// - Returns: レスポンスボディ。
    private func performData(_ request: URLRequest, notFoundSubject: NotFoundSubject? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            // Task キャンセル由来の失敗は制御信号のため変換せず伝播する（D2）。
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // 同上。
            throw urlError
        } catch let urlError as URLError {
            throw ApiFailure.network(urlError)
        } catch {
            // 本番の URLSession は URLError を投げる。test double 由来の任意の Error の受け皿。
            throw ApiFailure.network(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error]))
        }
        let hasAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        try validateResponse(response, hasAuthorization: hasAuthorization, notFoundSubject: notFoundSubject)
        return data
    }

    /// HTTP レスポンスのステータスを検証し、2xx 以外なら ``ApiFailure`` を投げる（D1）。
    /// - Parameters:
    ///   - response: 検証対象のレスポンス。
    ///   - hasAuthorization: このリクエストが Authorization ヘッダを付けていたか（I-S2 / CI-T14.8）。
    ///   - notFoundSubject: 404 が意味を持つ endpoint のときだけ渡す（D3）。宣言が無ければ
    ///     404 は `.unknown(status: 404)` になる。
    private func validateResponse(
        _ response: URLResponse,
        hasAuthorization: Bool,
        notFoundSubject: NotFoundSubject? = nil
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            // 非 HTTP 応答は fail-open ではなく fail-closed にする（CI-A02）。
            throw ApiFailure.network(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            // Authorization 付きリクエストの 401 だけ observer を 1 回呼ぶ（throw の意味は変えない）。
            if hasAuthorization { onUnauthorized?() }
            throw ApiFailure.unauthorized
        case 403:
            throw ApiFailure.forbidden
        case 404:
            if let notFoundSubject {
                throw ApiFailure.notFound(subject: notFoundSubject)
            }
            throw ApiFailure.unknown(status: 404)
        case 409:
            throw ApiFailure.conflict
        case 429:
            // Retry-After（秒）があれば添えて 429 専用エラーを投げる（issue #82）。
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
            throw ApiFailure.rateLimited(retryAfter: retryAfter)
        case 400:
            throw ApiFailure.validation
        case 500..<600:
            throw ApiFailure.server(status: http.statusCode)
        default:
            // 422 を含む、上記以外の 4xx・1xx・3xx（S4 で再判定するまで .validation に含めない）。
            throw ApiFailure.unknown(status: http.statusCode)
        }
    }
}
