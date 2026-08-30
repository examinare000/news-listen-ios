import XCTest
@testable import NewsListenApp

/// トランスクリプト推定タイミング（文字数按分）の純粋ロジックを検証する。
///
/// バックエンドはセグメント実時刻を提供しない（ADR-059 の既知の限界）ため、
/// 総再生時間を文字数で按分した推定オフセットを供給する。ここでは按分計算と
/// アクティブセグメント判定の境界を固定する。
final class TranscriptTimingTests: XCTestCase {

    // MARK: - offsets: 文字数按分

    func testEqualCharCountsYieldEqualSpacing() throws {
        let offsets = try XCTUnwrap(EstimatedTranscriptTiming.offsets(
            introCharCount: 0,
            segmentCharCounts: [10, 10, 10, 10],
            totalDuration: 100
        ))
        XCTAssertEqual(offsets, [0, 25, 50, 75])
    }

    func testIntroWeightShiftsAllOffsetsBackward() throws {
        // イントロ10文字 × 重み2.0 = 加重20。セグメント計20と合わせ加重40が40秒に対応し、
        // 1加重=1秒。先頭セグメントはイントロ分の20秒から始まる。
        let offsets = try XCTUnwrap(EstimatedTranscriptTiming.offsets(
            introCharCount: 10,
            segmentCharCounts: [10, 10],
            totalDuration: 40,
            japaneseCharWeight: 2.0
        ))
        XCTAssertEqual(offsets, [20, 30])
    }

    func testOffsetsAreMonotonicallyNonDecreasing() throws {
        let offsets = try XCTUnwrap(EstimatedTranscriptTiming.offsets(
            introCharCount: 5,
            segmentCharCounts: [3, 0, 42, 7, 0, 11],
            totalDuration: 613
        ))
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next)
        }
        XCTAssertEqual(offsets.count, 6)
    }

    func testZeroDurationReturnsNil() {
        XCTAssertNil(EstimatedTranscriptTiming.offsets(
            introCharCount: 0, segmentCharCounts: [10, 10], totalDuration: 0
        ))
    }

    func testEmptySegmentsReturnsNil() {
        XCTAssertNil(EstimatedTranscriptTiming.offsets(
            introCharCount: 10, segmentCharCounts: [], totalDuration: 100
        ))
    }

    func testAllZeroCharCountsReturnsNil() {
        XCTAssertNil(EstimatedTranscriptTiming.offsets(
            introCharCount: 0, segmentCharCounts: [0, 0], totalDuration: 100
        ))
    }

    // MARK: - activeSegmentIndex: 再生位置→アクティブ行

    func testActiveIndexIsNilDuringIntro() {
        // 先頭オフセット前（日本語イントロ推定区間）はハイライトしない。
        XCTAssertNil(EstimatedTranscriptTiming.activeSegmentIndex(offsets: [20, 30], currentTime: 19.9))
    }

    func testActiveIndexAtExactOffsetBoundary() {
        XCTAssertEqual(EstimatedTranscriptTiming.activeSegmentIndex(offsets: [20, 30], currentTime: 20), 0)
        XCTAssertEqual(EstimatedTranscriptTiming.activeSegmentIndex(offsets: [20, 30], currentTime: 30), 1)
    }

    func testActiveIndexBetweenOffsetsPicksEarlierSegment() {
        XCTAssertEqual(EstimatedTranscriptTiming.activeSegmentIndex(offsets: [0, 25, 50], currentTime: 24.9), 0)
    }

    func testActiveIndexBeyondEndClampsToLastSegment() {
        XCTAssertEqual(EstimatedTranscriptTiming.activeSegmentIndex(offsets: [0, 25, 50], currentTime: 9999), 2)
    }

    func testActiveIndexWithEmptyOffsetsIsNil() {
        XCTAssertNil(EstimatedTranscriptTiming.activeSegmentIndex(offsets: [], currentTime: 10))
    }

    // MARK: - TranscriptTimingProviding: Podcast からの供給

    func testProviderDerivesOffsetsFromPodcastFields() throws {
        // イントロ2文字 × 重み既定2.0 = 加重4、セグメント計4文字 → 加重8が80秒に対応。
        let podcast = Podcast(
            id: "p", type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://example.com/p.mp3", title: "t",
            japaneseIntroText: "導入",
            durationSeconds: 80, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0,
            segments: [
                TranscriptSegment(speaker: "A", text: "ab"),
                TranscriptSegment(speaker: "B", text: "cd"),
            ]
        )
        let offsets = try XCTUnwrap(EstimatedTranscriptTiming().segmentStartOffsets(for: podcast))
        XCTAssertEqual(offsets, [40, 60])
    }

    func testProviderReturnsNilWithoutSegments() {
        let podcast = Podcast(
            id: "p", type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://example.com/p.mp3", title: "t",
            japaneseIntroText: "",
            durationSeconds: 80, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        XCTAssertNil(EstimatedTranscriptTiming().segmentStartOffsets(for: podcast))
    }
}
