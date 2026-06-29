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
/// `AppState` への参照は SwiftUI 側から注入する。トークン/遷移先が `AppState` 設定前に
/// 届いた場合に備えて保留し、設定時にフラッシュする（コールドスタート対策）。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// アプリ状態。SwiftUI から注入される。設定時に保留中のトークン/遷移先を反映する。
    weak var appState: AppState? {
        didSet { flushPending() }
    }

    /// `AppState` 未設定時に届いたデバイストークン（16 進）。
    private var pendingDeviceToken: String?
    /// `AppState` 未設定時に届いた遷移先 Podcast ID。
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
        if let appState {
            appState.didRegisterDeviceToken(token)
        } else {
            pendingDeviceToken = token
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 登録失敗は致命的ではない（プッシュが届かないだけ）が、原因究明のため開発ビルドでのみ
        // 診断ログを出す（このエラーに機微情報・トークンは含まれない）。
        #if DEBUG
        print("[DEBUG] APNs registration failed: \(error.localizedDescription)")
        #endif
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
            if let appState {
                appState.handleNotificationPodcastId(podcastId)
            } else {
                pendingPodcastId = podcastId
            }
        }
        completionHandler()
    }

    /// `AppState` 設定時に、保留中のトークン/遷移先を反映する。
    private func flushPending() {
        guard let appState else { return }
        if let token = pendingDeviceToken {
            appState.didRegisterDeviceToken(token)
            pendingDeviceToken = nil
        }
        if let podcastId = pendingPodcastId {
            appState.handleNotificationPodcastId(podcastId)
            pendingPodcastId = nil
        }
    }
}
