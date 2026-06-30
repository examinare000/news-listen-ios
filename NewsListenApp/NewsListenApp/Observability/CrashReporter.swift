//
//  CrashReporter.swift
//  NewsListenApp
//
//  MetricKit のクラッシュ診断を受け取り backend /client-errors へ送る（issue #83）。
//
//  設計:
//  - MetricKit はクラッシュの「次回起動時」に診断をまとめて配信する。`@main` の init で購読登録する。
//  - 送信は認証不要（X-API-Key のみ）。クラッシュは未ログイン時にも起き得るため AppState/認証ライフ
//    サイクルに依存させず、ビルド注入の API 設定（Bundle）から独立した APIClient を構築する。
//  - MXCrashDiagnostic はテストで生成できないため、スクラブ/整形は純粋関数 ``CrashReportFormatter``
//    に分離して単体テスト可能にする（MetricKit 型から原始値を取り出して渡す）。
//  - PII の恐れがある自由記述（virtualMemoryRegionInfo 等）は送らない。
//

import Foundation
import MetricKit

/// MXCrashDiagnostic の原始値から送信ペイロードを組み立てる純粋関数群（テスト対象）。
enum CrashReportFormatter {
    /// クラッシュ診断の原始値から ``ClientErrorPayload`` を作る。
    /// - Note: 入力はすべて MetricKit 型ではなく原始値。PII を含み得る自由記述は受け取らない。
    static func payload(
        exceptionType: Int?,
        exceptionCode: Int?,
        signal: Int?,
        terminationReason: String?,
        appVersion: String?
    ) -> ClientErrorPayload {
        var context: [String: String] = [:]
        if let exceptionType { context["exception_type"] = String(exceptionType) }
        if let exceptionCode { context["exception_code"] = String(exceptionCode) }
        if let signal { context["signal"] = String(signal) }
        // applicationBuildVersion はビルド番号（CFBundleVersion）。正確に app_build と命名する。
        if let appVersion { context["app_build"] = appVersion }

        // terminationReason は OS の内部診断文字列。長大化を避けるため切り詰める。
        let message = terminationReason.map { String($0.prefix(500)) }

        return ClientErrorPayload(
            source: "ios",
            kind: "crash",
            message: message,
            context: context.isEmpty ? nil : context
        )
    }
}

/// MetricKit のクラッシュ診断を購読し backend へ転送するサブスクライバ。
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    /// 整形済みペイロードの送信処理（テストで差し替え可能にするため注入）。
    private let send: (ClientErrorPayload) -> Void

    /// - Parameter send: ペイロード送信処理。既定はビルド注入設定で構築した APIClient へ POST。
    init(send: @escaping (ClientErrorPayload) -> Void = CrashReporter.defaultSend) {
        self.send = send
    }

    /// MetricKit の診断購読を開始する（`@main` init から一度だけ呼ぶ）。
    func register() {
        MXMetricManager.shared.add(self)
    }

    // MARK: MXMetricManagerSubscriber

    /// クラッシュ等の診断ペイロードを受け取る（次回起動時にまとめて配信される）。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let report = CrashReportFormatter.payload(
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue,
                    terminationReason: crash.terminationReason,
                    appVersion: crash.metaData.applicationBuildVersion
                )
                send(report)
            }
        }
    }

    // MARK: 既定送信

    /// ビルド注入（Secrets.xcconfig→Info.plist）の API 設定で APIClient を構築し報告を送る。
    /// 失敗（設定欠如・通信エラー）は握りつぶす（クラッシュ報告で本処理を妨げない）。
    /// APIClient は MainActor 隔離のため、構築・送信を MainActor 上で行う。
    static func defaultSend(_ payload: ClientErrorPayload) {
        Task { @MainActor in
            guard let client = makeUnauthenticatedClient() else { return }
            try? await client.reportClientError(payload)
        }
    }

    /// クラッシュ報告用の APIClient（セッショントークン無し・X-API-Key のみ）。
    @MainActor
    private static func makeUnauthenticatedClient() -> APIClient? {
        guard let base = injectedValue("APIBaseURL"),
              let key = injectedValue("APIKey"),
              let url = URL(string: base) else { return nil }
        return APIClient(baseURL: url, apiKey: key, sessionToken: nil)
    }

    /// ビルド時注入値を読む（AppState と同じ規約。未注入や未置換は nil）。
    /// WHY: クラッシュ報告を AppState ライフサイクルへ結合させないため、設定読取を本クラスに閉じる。
    private static func injectedValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
