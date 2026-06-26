//
//  ASAuthorizationPasskeyProvider.swift
//  NewsListenApp
//
//  AuthenticationServices / UIKit を import する唯一のファイル。
//  PasskeyAuthorizationProviding プロトコルを実装し、ASAuthorizationController を薄くラップする。
//  ASAuthorization の delegate コールバックをドメイン credential に詰め替えるだけの「極薄」殻。
//  このファイルは Unit Test 対象外（ASAuthorizationController は UI 操作が必要）。
//

import AuthenticationServices
import Foundation

// UIKit は ASPresentationAnchor の取得に必要。
#if canImport(UIKit)
import UIKit
#endif

/// Passkey 操作の本番実装。AuthenticationServices の ASAuthorizationController をラップする。
///
/// - Note: `ASAuthorizationController.delegate` は `weak` なため、`retainedDelegate` でプロバイダ側が保持する。
///   単一の同時実行を想定（複数同時呼び出しは最後のもので上書きされる）。
@MainActor
final class ASAuthorizationPasskeyProvider: NSObject, PasskeyAuthorizationProviding {

    // ASAuthorizationController の weak 参照対策で保持する。`withCheckedThrowingContinuation`
    // の @Sendable クロージャ（nonisolated）から代入するため nonisolated(unsafe) とする。
    // 生成・代入・解放はすべて MainActor 上の単一フローで行われるため実行時は安全。
    /// 実行中の登録デリゲート。
    nonisolated(unsafe) private var retainedRegistrationDelegate: PasskeyRegistrationDelegate?
    /// 実行中の認証デリゲート。
    nonisolated(unsafe) private var retainedAssertionDelegate: PasskeyAssertionDelegate?

    // MARK: - PasskeyAuthorizationProviding

    func createCredential(_ options: PasskeyRegistrationOptions) async throws -> PasskeyRegistrationCredential {
        try await withCheckedThrowingContinuation { continuation in
            let rpProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: options.rpID
            )
            // 表示名はプラットフォーム認証器では `name` が account 名として使われる。
            // ...RegistrationRequest に displayName 設定 API は無いため name のみ指定する。
            let request = rpProvider.createCredentialRegistrationRequest(
                challenge: options.challenge,
                name: options.userName,
                userID: options.userID
            )

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = PasskeyRegistrationDelegate(continuation: continuation)
            retainedRegistrationDelegate = delegate
            controller.delegate = delegate
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func assertCredential(_ options: PasskeyAssertionOptions) async throws -> PasskeyAssertionCredential {
        try await withCheckedThrowingContinuation { continuation in
            let rpProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: options.rpID
            )
            let request = rpProvider.createCredentialAssertionRequest(challenge: options.challenge)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = PasskeyAssertionDelegate(continuation: continuation)
            retainedAssertionDelegate = delegate
            controller.delegate = delegate
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension ASAuthorizationPasskeyProvider: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
#if canImport(UIKit)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? ASPresentationAnchor()
#else
        ASPresentationAnchor()
#endif
    }
}

// MARK: - Private delegate: Registration

/// 登録コールバックを CheckedContinuation へ橋渡しする内部デリゲート。
private final class PasskeyRegistrationDelegate: NSObject, ASAuthorizationControllerDelegate {

    private let continuation: CheckedContinuation<PasskeyRegistrationCredential, Error>

    init(continuation: CheckedContinuation<PasskeyRegistrationCredential, Error>) {
        self.continuation = continuation
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let reg = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            continuation.resume(
                throwing: PasskeyError.failed(
                    NSError(domain: "ASAuthorizationPasskeyProvider", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"])
                )
            )
            return
        }
        continuation.resume(returning: PasskeyRegistrationCredential(
            credentialID: reg.credentialID,
            clientDataJSON: reg.rawClientDataJSON,
            // rawAttestationObject は attestation 無し登録で nil になりうる（Optional Data）。
            attestationObject: reg.rawAttestationObject ?? Data(),
            // iOS プラットフォーム認証器のトランスポートは "internal"。
            transports: ["internal"]
        ))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            continuation.resume(throwing: PasskeyError.canceled)
        } else {
            continuation.resume(throwing: PasskeyError.failed(error))
        }
    }
}

// MARK: - Private delegate: Assertion

/// 認証コールバックを CheckedContinuation へ橋渡しする内部デリゲート。
private final class PasskeyAssertionDelegate: NSObject, ASAuthorizationControllerDelegate {

    private let continuation: CheckedContinuation<PasskeyAssertionCredential, Error>

    init(continuation: CheckedContinuation<PasskeyAssertionCredential, Error>) {
        self.continuation = continuation
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let assert = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            continuation.resume(
                throwing: PasskeyError.failed(
                    NSError(domain: "ASAuthorizationPasskeyProvider", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"])
                )
            )
            return
        }
        // userID は WebAuthn の userHandle に相当する。空データは nil 扱いにする。
        let userHandle: Data? = assert.userID.isEmpty ? nil : assert.userID
        continuation.resume(returning: PasskeyAssertionCredential(
            credentialID: assert.credentialID,
            clientDataJSON: assert.rawClientDataJSON,
            authenticatorData: assert.rawAuthenticatorData,
            signature: assert.signature,
            userHandle: userHandle
        ))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            continuation.resume(throwing: PasskeyError.canceled)
        } else {
            continuation.resume(throwing: PasskeyError.failed(error))
        }
    }
}
