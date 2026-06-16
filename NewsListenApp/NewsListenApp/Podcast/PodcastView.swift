//
//  PodcastView.swift
//  NewsListenApp
//
//  プレースホルダ。Task 6 で一覧・AVPlayer 再生を実装して差し替える。
//

import SwiftUI

struct PodcastView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Podcast", systemImage: "headphones", description: Text("Task 6 で実装"))
                .navigationTitle("Podcast")
        }
    }
}
