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
    /// レスポンスボディの JSON デコードに失敗した。
    case decodingError(Error)

    /// ユーザー向けのエラー説明文。
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP Error \(code)"
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
    /// `X-API-Key` ヘッダに付与する API キー。
    private let apiKey: String
    /// 実通信を行うセッション。テスト時はモックを注入する。
    private let session: URLSessionProtocol
    /// レスポンスボディのデコードに使う JSON デコーダ。
    private let decoder: JSONDecoder

    /// クライアントを生成する。
    /// - Parameters:
    ///   - baseURL: API のベース URL。
    ///   - apiKey: `X-API-Key` ヘッダに付与する API キー。
    ///   - session: 通信に使うセッション。既定は `URLSession.shared`。
    init(baseURL: URL, apiKey: String, session: URLSessionProtocol = URLSession.shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
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

    // MARK: - Settings

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
        let (_, response) = try await session.data(for: req)
        try validateResponse(response)
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
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}
