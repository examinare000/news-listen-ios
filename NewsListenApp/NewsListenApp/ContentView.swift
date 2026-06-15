//
//  ContentView.swift
//  NewsListenApp
//
//  Created by 池田遼介 on 2026/06/14.
//

import SwiftUI

// セットアップ段階のプレースホルダ。
// Task 4 でタブ構成（Feed / Podcast / Settings）に置き換える。
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("NewsListenApp")
                .font(.headline)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
