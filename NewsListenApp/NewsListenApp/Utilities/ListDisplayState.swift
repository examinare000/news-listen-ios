//
//  ListDisplayState.swift
//  NewsListenApp
//
//  一覧画面（Feed / Podcast）の表示状態を判定する共有ヘルパ。
//  ロード失敗と「本当に空」を同一の空状態に畳んで表示してしまうと、通信エラーなのに
//  再取得導線の無い空画面になる不具合（issue #53）を防ぐため、View の分岐ロジックを
//  この純粋関数のみで決定する。
//

import Foundation

/// 一覧画面の表示状態。
enum ListDisplayState: Equatable {
    /// 初回ロード中（一覧はまだ空）。
    case loading
    /// ロード失敗かつ一覧が空。再試行導線を伴うエラー表示にする。
    case error(message: String)
    /// ロード成功かつ本当に一覧が空。
    case empty
    /// 一覧に表示する項目がある。
    case content

    /// 現在の状態から表示状態を導出する。
    ///
    /// 一覧に項目があれば、ロード中やエラーメッセージが残っていても一覧を優先する
    /// （エラーは別途アラートで表示済みのため、空状態表示には畳まない）。
    /// - Parameters:
    ///   - isLoading: ロード中かどうか。
    ///   - isEmpty: 一覧が空かどうか。
    ///   - errorMessage: 直近のエラーメッセージ（なければ `nil`）。
    static func resolve(isLoading: Bool, isEmpty: Bool, errorMessage: String?) -> ListDisplayState {
        guard isEmpty else { return .content }
        if isLoading { return .loading }
        if let errorMessage { return .error(message: errorMessage) }
        return .empty
    }

    /// エラーアラートを表示すべきかどうかを判定する（issue #58）。
    ///
    /// `errorMessage` の有無のみで `.alert` を出すと、一覧が空の場合に `.error` のインライン表示と
    /// 二重表示になる。この状態（`displayState` が `.error`）ではアラートを出さない。
    /// - Parameters:
    ///   - errorMessage: 直近のエラーメッセージ（なければ `nil`）。
    ///   - displayState: `resolve(isLoading:isEmpty:errorMessage:)` が返した表示状態。
    static func shouldPresentAlert(errorMessage: String?, displayState: ListDisplayState) -> Bool {
        guard errorMessage != nil else { return false }
        if case .error = displayState { return false }
        return true
    }
}
