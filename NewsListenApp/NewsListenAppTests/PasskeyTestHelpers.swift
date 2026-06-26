import Foundation
@testable import NewsListenApp

// MARK: - MockPasskeyProvider

/// テスト用 Passkey プロバイダ。
/// 返却値とエラーを事前設定し、呼び出されたオプションを記録する。
final class MockPasskeyProvider: PasskeyAuthorizationProviding {

    // MARK: Configurable results

    /// `assertCredential` の返却値。デフォルトは canceled throw。
    var assertResult: Result<PasskeyAssertionCredential, Error> = .failure(PasskeyError.canceled)
    /// `createCredential` の返却値。デフォルトは canceled throw。
    var createResult: Result<PasskeyRegistrationCredential, Error> = .failure(PasskeyError.canceled)

    // MARK: Recording

    /// 最後に渡された assertion options。
    private(set) var receivedAssertionOptions: PasskeyAssertionOptions?
    /// 最後に渡された registration options。
    private(set) var receivedRegistrationOptions: PasskeyRegistrationOptions?

    /// `assertCredential` が呼ばれた回数。
    private(set) var assertCallCount = 0
    /// `createCredential` が呼ばれた回数。
    private(set) var createCallCount = 0

    // MARK: PasskeyAuthorizationProviding

    func assertCredential(_ options: PasskeyAssertionOptions) async throws -> PasskeyAssertionCredential {
        assertCallCount += 1
        receivedAssertionOptions = options
        switch assertResult {
        case .success(let cred): return cred
        case .failure(let error): throw error
        }
    }

    func createCredential(_ options: PasskeyRegistrationOptions) async throws -> PasskeyRegistrationCredential {
        createCallCount += 1
        receivedRegistrationOptions = options
        switch createResult {
        case .success(let cred): return cred
        case .failure(let error): throw error
        }
    }
}

// MARK: - SequentialMockSession

/// 順番に異なるレスポンスを返すモックセッション（ViewModel テストの多段通信シナリオ用）。
/// `SettingsViewModelTests` の `SequentialSession`（private）と区別するため名前を変える。
final class SequentialMockSession: URLSessionProtocol {

    struct Response {
        let data: Data
        let statusCode: Int
    }

    private var queue: [Response]

    init(_ responses: [Response]) {
        self.queue = responses
    }

    /// 残りがなければ 200 の空データを返す（テストの想定外呼び出し検出に使う）。
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let item = queue.isEmpty ? Response(data: Data(), statusCode: 200) : queue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: item.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (item.data, response)
    }
}

// MARK: - PasskeyAssertionCredential factory

extension MockPasskeyProvider {
    /// テスト用の assertion credential を生成するユーティリティ。
    static func makeAssertionCredential(
        credentialID: Data = Data("mock-cred-id".utf8),
        clientDataJSON: Data = Data("mock-cdj".utf8),
        authenticatorData: Data = Data("mock-auth".utf8),
        signature: Data = Data("mock-sig".utf8),
        userHandle: Data? = Data("mock-user".utf8)
    ) -> PasskeyAssertionCredential {
        PasskeyAssertionCredential(
            credentialID: credentialID,
            clientDataJSON: clientDataJSON,
            authenticatorData: authenticatorData,
            signature: signature,
            userHandle: userHandle
        )
    }

    /// テスト用の registration credential を生成するユーティリティ。
    static func makeRegistrationCredential(
        credentialID: Data = Data("mock-cred-id".utf8),
        clientDataJSON: Data = Data("mock-cdj".utf8),
        attestationObject: Data = Data("mock-attest".utf8),
        transports: [String] = ["internal"]
    ) -> PasskeyRegistrationCredential {
        PasskeyRegistrationCredential(
            credentialID: credentialID,
            clientDataJSON: clientDataJSON,
            attestationObject: attestationObject,
            transports: transports
        )
    }
}
