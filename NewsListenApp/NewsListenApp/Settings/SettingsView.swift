//
//  SettingsView.swift
//  NewsListenApp
//
//  プレースホルダ。Task 7 で RSS ソース管理・難易度設定を実装して差し替える。
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("設定", systemImage: "gearshape", description: Text("Task 7 で実装"))
                .navigationTitle("設定")
        }
    }
}
