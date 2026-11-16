//
//  CrashReporter.swift
//  NewsListenApp
//
//  MetricKit のクラッシュ診断を受け取り backend /client-errors へ送る（issue #83）。
//
//  設計:
//  - MetricKit はクラッシュの「次回起動時」に診断をまとめて配信する。`@main` の init で購読登録する。
//  - 送信は認証不要（X-API-Key のみ）。クラッシュは未ログイン時にも起き得るため AppState/認証ライフ
//    サイクルに依存させず、送信処理は合成 root が（token 無しの client で）注入する。
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
    /// 整形済みペイロードの送信処理。合成 root が、ビルド注入の API 設定で作る client への POST を渡す。
    private let send: (ClientErrorPayload) -> Void

    /// - Parameter send: ペイロード送信処理。失敗（設定欠如・通信エラー）の握りつぶしは送信側が持つ。
    init(send: @escaping (ClientErrorPayload) -> Void) {
        self.send = send
    }

    /// 整形済みのクラッシュ報告を送信処理へ渡す。`didReceive` が整形して呼ぶ。
    func report(_ payload: ClientErrorPayload) {
        send(payload)
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
                let formatted = CrashReportFormatter.payload(
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue,
                    terminationReason: crash.terminationReason,
                    appVersion: crash.metaData.applicationBuildVersion
                )
                report(formatted)
            }
        }
    }
}
