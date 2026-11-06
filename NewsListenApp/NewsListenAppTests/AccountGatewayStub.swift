import XCTest
@testable import NewsListenApp

/// `AccountGateway` の test double。テストで `AccountGateway(...)` を直接組むのはこのファイルだけ。
///
/// 16 の closure すべてに既定値を持つ。既定の closure は呼ばれたら `XCTFail` して投げるので、
/// 「この操作では gateway を呼ばない」ことは何も渡さないことで表せる。
struct UnexpectedGatewayCall: Error, Equatable {
    let name: String
}

extension AccountGateway {
    static func stub(
        updateProfile: @escaping (String) async throws -> Subject = { _ in
            XCTFail("updateProfile は呼ばれない"); throw UnexpectedGatewayCall(name: "updateProfile")
        },
        changePassword: @escaping (String, String) async throws -> Void = { _, _ in
            XCTFail("changePassword は呼ばれない"); throw UnexpectedGatewayCall(name: "changePassword")
        },
        login: @escaping (String, String) async throws -> LoginReceipt = { _, _ in
            XCTFail("login は呼ばれない"); throw UnexpectedGatewayCall(name: "login")
        },
        listSessions: @escaping () async throws -> [DeviceSession] = {
            XCTFail("listSessions は呼ばれない"); throw UnexpectedGatewayCall(name: "listSessions")
        },
        revokeSession: @escaping (String) async throws -> Void = { _ in
            XCTFail("revokeSession は呼ばれない"); throw UnexpectedGatewayCall(name: "revokeSession")
        },
        revokeOtherSessions: @escaping () async throws -> Int = {
            XCTFail("revokeOtherSessions は呼ばれない"); throw UnexpectedGatewayCall(name: "revokeOtherSessions")
        },
        passkeyRegisterOptions: @escaping () async throws -> (challengeID: String, options: PasskeyRegistrationOptions) = {
            XCTFail("passkeyRegisterOptions は呼ばれない"); throw UnexpectedGatewayCall(name: "passkeyRegisterOptions")
        },
        passkeyRegisterVerify: @escaping (String, PasskeyRegistrationCredential) async throws -> Void = { _, _ in
            XCTFail("passkeyRegisterVerify は呼ばれない"); throw UnexpectedGatewayCall(name: "passkeyRegisterVerify")
        },
        passkeyLoginOptions: @escaping () async throws -> (challengeID: String, options: PasskeyAssertionOptions) = {
            XCTFail("passkeyLoginOptions は呼ばれない"); throw UnexpectedGatewayCall(name: "passkeyLoginOptions")
        },
        passkeyLoginVerify: @escaping (String, PasskeyAssertionCredential) async throws -> LoginReceipt = { _, _ in
            XCTFail("passkeyLoginVerify は呼ばれない"); throw UnexpectedGatewayCall(name: "passkeyLoginVerify")
        },
        listPasskeyCredentials: @escaping () async throws -> [PasskeyCredential] = {
            XCTFail("listPasskeyCredentials は呼ばれない"); throw UnexpectedGatewayCall(name: "listPasskeyCredentials")
        },
        deletePasskeyCredential: @escaping (String) async throws -> Void = { _ in
            XCTFail("deletePasskeyCredential は呼ばれない"); throw UnexpectedGatewayCall(name: "deletePasskeyCredential")
        },
        listUsers: @escaping () async throws -> [Subject] = {
            XCTFail("listUsers は呼ばれない"); throw UnexpectedGatewayCall(name: "listUsers")
        },
        createUser: @escaping (String, String, String?, Role) async throws -> Void = { _, _, _, _ in
            XCTFail("createUser は呼ばれない"); throw UnexpectedGatewayCall(name: "createUser")
        },
        updateUserRole: @escaping (String, Role) async throws -> Void = { _, _ in
            XCTFail("updateUserRole は呼ばれない"); throw UnexpectedGatewayCall(name: "updateUserRole")
        },
        deleteUser: @escaping (String) async throws -> Void = { _ in
            XCTFail("deleteUser は呼ばれない"); throw UnexpectedGatewayCall(name: "deleteUser")
        }
    ) -> AccountGateway {
        AccountGateway(
            updateProfile: updateProfile,
            changePassword: changePassword,
            login: login,
            listSessions: listSessions,
            revokeSession: revokeSession,
            revokeOtherSessions: revokeOtherSessions,
            passkeyRegisterOptions: passkeyRegisterOptions,
            passkeyRegisterVerify: passkeyRegisterVerify,
            passkeyLoginOptions: passkeyLoginOptions,
            passkeyLoginVerify: passkeyLoginVerify,
            listPasskeyCredentials: listPasskeyCredentials,
            deletePasskeyCredential: deletePasskeyCredential,
            listUsers: listUsers,
            createUser: createUser,
            updateUserRole: updateUserRole,
            deleteUser: deleteUser
        )
    }
}
