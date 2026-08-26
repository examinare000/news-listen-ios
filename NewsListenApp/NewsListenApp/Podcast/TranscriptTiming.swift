//
//  TranscriptTiming.swift
//  NewsListenApp
//
//  トランスクリプト各セグメントの推定開始時刻を供給する。
//  バックエンドはセグメント実時刻を持たない（ADR-059 の既知の限界）ため、
//  現状は総再生時間の文字数按分による推定のみ。実時刻が提供されたら
//  TranscriptTimingProviding の別実装へ差し替える。
//

import Foundation

/// トランスクリプト各セグメントの開始時刻（秒）を供給する差し替え点。
///
/// 将来バックエンドが `segments[].start_seconds` を返すようになったら、
/// 実時刻を優先する実装を追加してここを差し替える（UI 側は本 protocol にのみ依存する）。
protocol TranscriptTimingProviding {
    /// 各セグメントの推定開始秒（`podcast.segments` と同順・同数）。
    /// 算出不能（duration 0・セグメント無し・文字数計 0）なら nil。
    func segmentStartOffsets(for podcast: Podcast) -> [Double]?
}

/// 文字数按分による推定タイミング。
///
/// 音声は「日本語イントロ → 英語対話」の連結1本で、`durationSeconds` はその全体長。
/// 日本語イントロは文字あたりの発話時間が英語と異なるため、重み係数を掛けた擬似
/// セグメントとして按分の先頭に組み込み、英語対話の開始オフセットを推定する。
struct EstimatedTranscriptTiming: TranscriptTimingProviding {

    /// 日本語1文字あたりの相対発話時間（英語1文字 = 1.0 基準）。
    ///
    /// 調整手順: 実エピソードで最初の英語セグメントのハイライト開始が実音声より
    /// 早い（イントロ中に点灯する）なら値を上げ、遅いなら下げる。TTS 話速変更時も
    /// ここだけを再調整すればよい。
    static let japaneseCharWeight: Double = 2.0

    func segmentStartOffsets(for podcast: Podcast) -> [Double]? {
        guard let segments = podcast.segments else { return nil }
        return Self.offsets(
            introCharCount: podcast.japaneseIntroText.count,
            segmentCharCounts: segments.map { $0.text.count },
            totalDuration: Double(podcast.durationSeconds)
        )
    }

    /// 文字数按分で各セグメントの推定開始秒を求める（純粋関数）。
    ///
    /// - Parameters:
    ///   - introCharCount: 日本語イントロの文字数（音声先頭に連結されている）。
    ///   - segmentCharCounts: 各セグメントの文字数（表示順）。
    ///   - totalDuration: 音声全体の長さ（秒・イントロ込み）。
    ///   - japaneseCharWeight: 日本語文字の相対重み（既定 ``japaneseCharWeight``）。
    /// - Returns: 各セグメントの推定開始秒。算出不能なら nil。
    static func offsets(
        introCharCount: Int,
        segmentCharCounts: [Int],
        totalDuration: Double,
        japaneseCharWeight: Double = japaneseCharWeight
    ) -> [Double]? {
        guard totalDuration > 0, !segmentCharCounts.isEmpty else { return nil }
        // セグメント文字数計 0 は按分先が無い（全オフセットが同値に潰れる）ため算出不能扱い。
        let segmentTotal = segmentCharCounts.reduce(0, +)
        guard segmentTotal > 0 else { return nil }

        let introWeight = Double(introCharCount) * japaneseCharWeight
        let totalWeight = introWeight + Double(segmentTotal)
        let secondsPerWeight = totalDuration / totalWeight

        var offsets: [Double] = []
        offsets.reserveCapacity(segmentCharCounts.count)
        var accumulatedWeight = introWeight
        for count in segmentCharCounts {
            offsets.append(accumulatedWeight * secondsPerWeight)
            accumulatedWeight += Double(count)
        }
        return offsets
    }

    /// 再生位置に対応するアクティブセグメントの index を返す（純粋関数）。
    ///
    /// 先頭オフセット前（日本語イントロ推定区間）は nil（ハイライトなし）。
    /// 末尾を超えた位置は最終セグメントに丸める。
    static func activeSegmentIndex(offsets: [Double], currentTime: Double) -> Int? {
        var active: Int?
        for (index, offset) in offsets.enumerated() where offset <= currentTime {
            active = index
        }
        return active
    }
}
