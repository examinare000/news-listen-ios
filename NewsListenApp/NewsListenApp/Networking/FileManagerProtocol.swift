//
//  FileManagerProtocol.swift
//  NewsListenApp
//
//  FileManager の抽象化。テストでモックを注入可能にする。
//

import Foundation

/// `FileManager` を差し替え可能にしてテストでモックを注入するための抽象。
protocol FileManagerProtocol {
    /// 指定パスにファイルが存在するかどうか。
    func fileExists(atPath: String) -> Bool
    /// ディレクトリを作成する。中間ディレクトリも必要に応じて作成する。
    func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    /// 指定パスのファイル/ディレクトリを削除する。
    func removeItem(at: URL) throws
    /// Data をファイルに書き込む。
    func write(_ data: Data, to: URL) throws
    /// 指定パスのファイルサイズを返す（存在しないか読み込めない場合は `nil`）。
    func fileSize(atPath: String) -> Int64?
    /// キャッシュディレクトリの URL を返す。
    func cachesDirectory() -> URL
}

extension FileManager: FileManagerProtocol {
    // createDirectory(at:withIntermediateDirectories:attributes:) は FileManager の
    // ネイティブメソッドが protocol 要件を満たすため、ここでは再定義しない（再定義すると自己再帰）。

    func write(_ data: Data, to: URL) throws {
        try data.write(to: to)
    }

    func fileSize(atPath: String) -> Int64? {
        guard let attrs = try? attributesOfItem(atPath: atPath) else { return nil }
        return attrs[.size] as? Int64
    }

    func cachesDirectory() -> URL {
        urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}
