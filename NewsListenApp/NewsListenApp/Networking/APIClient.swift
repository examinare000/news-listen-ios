//
//  APIClient.swift
//  NewsListenApp
//
//  URLSession ベースの API クライアント。X-API-Key ヘッダ付与・JSON デコード・
//  HTTP ステータス検証を一元化する。テスト用に URLSessionProtocol で注入可能にする。
//

import Foundation

// URLSession を差し替え可能にしてテストでモックを注入する。
protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

enum APIError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP Error \(code)"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class APIClient: ObservableObject {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSessionProtocol
    private let decoder: JSONDecoder

    init(baseURL: URL, apiKey: String, session: URLSessionProtocol = URLSession.shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - Feed

    func fetchFeed() async throws -> FeedResponse {
        try await request(.feed, responseType: FeedResponse.self)
    }

    func starArticle(id: String) async throws {
        try await requestVoid(.starArticle(id: id))
    }

    func dismissArticle(id: String) async throws {
        try await requestVoid(.dismissArticle(id: id))
    }

    // MARK: - Podcasts

    func fetchPodcasts() async throws -> PodcastListResponse {
        try await request(.podcasts, responseType: PodcastListResponse.self)
    }

    // MARK: - Settings

    func fetchSources() async throws -> RssSourcesResponse {
        try await request(.sources, responseType: RssSourcesResponse.self)
    }

    func addSource(name: String, url: String) async throws -> RssSourcesResponse {
        let body = ["name": name, "url": url]
        return try await request(.addSource, body: body, responseType: RssSourcesResponse.self)
    }

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

    private func requestVoid(_ endpoint: APIEndpoint, body: [String: Any]? = nil) async throws {
        let req = try buildRequest(endpoint, body: body)
        let (_, response) = try await session.data(for: req)
        try validateResponse(response)
    }

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

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200..<300 ~= http.statusCode else {
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}
