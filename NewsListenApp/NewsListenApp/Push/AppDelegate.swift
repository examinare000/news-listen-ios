//
//  AppDelegate.swift
//  NewsListenApp
//
//  APNs プッシュ通知（issue #80）のための UIApplicationDelegate。
//  通知許可リクエスト・リモート通知登録・デバイストークン受領・通知タップ遷移を担う。
//  純 SwiftUI ライフサイクルに `@UIApplicationDelegateAdaptor` で接続する。
//

import UIKit
import UserNotifications

/// APNs 登録と通知ハンドリングを担う AppDelegate。
///
/// `PushRegistration` への参照は SwiftUI 側から注入する。トークン/遷移先が `PushRegistration` 設定前に
/// 届いた場合に備えて保留し、設定時にフラッシュする（コールドスタート対策）。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 通知の登録と保留。SwiftUI から注入される。設定時に保留中のトークン/遷移先を反映する。
    weak var pushRegistration: PushRegistration? {
        didSet { flushPending() }
    }

    /// `PushRegistration` 未設定時に届いたデバイストークン（16 進）。
    private var pendingDeviceToken: String?
    /// `PushRegistration` 未設定時に届いた遷移先 Podcast ID。
    private var pendingPodcastId: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationAndRegister()
        return true
    }

    /// 通知許可をリクエストし、許可されればリモート通知登録を行う。
    private func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = DeviceTokenFormatter.hexString(from: deviceToken)
        if let pushRegistration {
            pushRegistration.didReceiveDeviceToken(token)
        } else {
            pendingDeviceToken = token
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 登録失敗は致命的ではない（プッシュが届かないだけ）ため、握りつぶす。
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// フォアグラウンドでも通知をバナー表示する。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 通知タップ時、ペイロードの podcast_id へ遷移する。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let podcastId = PushPayload.podcastId(from: response.notification.request.content.userInfo) {
            if let pushRegistration {
                pushRegistration.openEpisode(id: podcastId)
            } else {
                pendingPodcastId = podcastId
            }
        }
        completionHandler()
    }

    /// `PushRegistration` 設定時に、保留中のトークン/遷移先を反映する。
    private func flushPending() {
        guard let pushRegistration else { return }
        if let token = pendingDeviceToken {
            pushRegistration.didReceiveDeviceToken(token)
            pendingDeviceToken = nil
        }
        if let podcastId = pendingPodcastId {
            pushRegistration.openEpisode(id: podcastId)
            pendingPodcastId = nil
        }
    }
}
