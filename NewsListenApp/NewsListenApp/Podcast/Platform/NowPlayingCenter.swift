//
//  NowPlayingCenter.swift
//  NewsListenApp
//
//  ロック画面/コントロールセンターの再生情報表示を隠す port（I-S2 では `clear()` のみ）。
//  `update` / `registerCommands` 等の他操作の port 化は I-S3a/I-S3b2 で行う。
//

import Foundation

/// `MPNowPlayingInfoCenter` を隠す port。`AppState` / `Auth/SubjectCleanup.swift` はこの
/// protocol だけを参照し、`MediaPlayer` を import しない（leakage 検査: grep oracle O-6）。
protocol NowPlayingCenter {
    /// ロック画面/コントロールセンターの再生情報表示を消す。
    func clear()
}
