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

/// API 通信で発生しうるエラー。
enum APIError: LocalizedError {
    /// URL の生成・解釈に失敗した。
    case invalidURL
    /// HTTP ステータスが 2xx 以外だった。
    case httpError(statusCode: Int)
    /// 生成上限など 429 Too Many Requests（Retry-After 秒・issue #82）。
    /// 既存の `httpError(404)` 等のパターンを壊さないよう 429 専用の別ケースにする。
    case rateLimited(retryAfter: Int?)
    /// レスポンスボディの JSON デコードに失敗した。
    case decodingError(Error)

    /// ユーザー向けのエラー説明文。
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP Error \(code)"
        case .rateLimited: return "リクエストが多すぎます。しばらくしてからお試しください。"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        }
    }
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

    /// クライアントを生成する。
    /// - Parameters:
    ///   - baseURL: API のベース URL。
    ///   - apiKey: `X-API-Key` ヘッダに付与する API キー。
    ///   - sessionToken: ユーザー認証用のセッショントークン（未ログイン時は `nil`）。
    ///   - session: 通信に使うセッション。既定は `URLSession.shared`。
    init(
        baseURL: URL,
        apiKey: String,
        sessionToken: String? = nil,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionToken = sessionToken
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - Feed

    /// フィードの記事一覧を取得する。
    func fetchFeed() async throws -> FeedResponse {
        try await request(.feed, responseType: FeedResponse.self)
    }

    /// 指定 ID の記事を Star する。
    /// - Parameter id: 対象記事の ID。
    func starArticle(id: String) async throws {
        try await requestVoid(.starArticle(id: id))
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

    /// 指定 URL から音声データをダウンロードする。
    ///
    /// **セキュリティ**: 外部署名 URL（GCS 等）に対してヘッダを付けない。
    /// X-API-Key・Authorization は付与せず、URLRequest をそのまま実行する。
    /// - Parameter url: 音声ファイルの URL。
    /// - Returns: 音声データ。
    func downloadAudio(from url: URL) async throws -> Data {
        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return data
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
    func updatePreferences(defaultDifficulty: String?, defaultPlaybackSpeed: Double?) async throws -> Preferences {
        var body: [String: Any] = [:]
        if let defaultDifficulty { body["default_difficulty"] = defaultDifficulty }
        if let defaultPlaybackSpeed { body["default_playback_speed"] = defaultPlaybackSpeed }
        return try await request(.updatePreferences, body: body, responseType: Preferences.self)
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
        let (_, response) = try await session.data(for: req)
        try validateResponse(response)
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
        try await requestVoid(.passkeyDeleteCredential(id: id))
    }

    /// 自分の有効セッション（ログイン中デバイス）一覧を取得する（Bearer 要・issue #84）。
    func listSessions() async throws -> SessionsAPIResponse {
        try await request(.sessions, responseType: SessionsAPIResponse.self)
    }

    /// 指定セッションを個別失効する（Bearer 要・他人/不在は 404・冪等）。
    func revokeSession(id: String) async throws {
        try await requestVoid(.revokeSession(id: id))
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
    ///   - responseType: デコード先の型。
    private func request<T: Decodable>(
        _ endpoint: APIEndpoint,
        body: [String: Any]? = nil,
        responseType: T.Type
    ) async throws -> T {
        let req = try buildRequest(endpoint, body: body)
        let (data, response) = try await session.data(for: req)
        try validateResponse(response)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// レスポンスボディを必要としないリクエストを送り、ステータス検証のみ行う。
    /// - Parameters:
    ///   - endpoint: 対象エンドポイント。
    ///   - body: 送信する JSON ボディ（任意）。
    private func requestVoid(_ endpoint: APIEndpoint, body: [String: Any]? = nil) async throws {
        let req = try buildRequest(endpoint, body: body)
        let (_, response) = try await session.data(for: req)
        try validateResponse(response)
    }

    /// エンドポイントと任意のボディから、API キー付きの `URLRequest` を組み立てる。
    /// - Parameters:
    ///   - endpoint: 対象エンドポイント。
    ///   - body: JSON 化して送信するボディ（任意）。
    private func buildRequest(_ endpoint: APIEndpoint, body: [String: Any]?) throws -> URLRequest {
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

    /// HTTP レスポンスのステータスを検証し、2xx 以外なら ``APIError/httpError(statusCode:)`` を投げる。
    /// - Parameter response: 検証対象のレスポンス。
    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 {
                // Retry-After（秒）があれば添えて 429 専用エラーを投げる（issue #82）。
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
                throw APIError.rateLimited(retryAfter: retryAfter)
            }
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}
