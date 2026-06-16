//
//  FeedView.swift
//  NewsListenApp
//
//  プレースホルダ。Task 5 で記事一覧・スワイプ操作を実装して差し替える。
//

import SwiftUI

struct FeedView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("フィード", systemImage: "newspaper", description: Text("Task 5 で実装"))
                .navigationTitle("フィード")
        }
    }
}
