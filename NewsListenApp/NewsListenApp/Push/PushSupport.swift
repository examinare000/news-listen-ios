//
//  PushSupport.swift
//  NewsListenApp
//
//  APNs プッシュ通知（issue #80）の純粋ヘルパ。デバイストークンの 16 進整形と、
//  通知ペイロードからの遷移先抽出を、UIKit/UNUserNotification の副作用から切り離して
//  単体テスト可能にする。
//

import Foundation

/// APNs デバイストークン（`Data`）を backend へ送る 16 進文字列へ整形する。
enum DeviceTokenFormatter {
    /// `Data` を小文字 16 進文字列へ変換する（APNs トークンの標準表現）。
    /// - Parameter data: `didRegisterForRemoteNotificationsWithDeviceToken` で受け取るトークン。
    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// APNs 通知ペイロードから遷移先情報を取り出す。
enum PushPayload {
    /// 通知ペイロードから遷移先の Podcast ID を取り出す（無ければ nil）。
    ///
    /// backend は生成完了通知の `data` に `podcast_id` を載せる（ADR-020）。
    /// - Parameter userInfo: `UNNotificationContent.userInfo`。
    static func podcastId(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["podcast_id"] as? String
    }
}
