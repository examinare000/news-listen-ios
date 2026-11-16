//
//  ResumeChoiceView.swift
//  NewsListenApp
//
//  再開時の確認（別の端末の位置から続けるか、この端末の位置から続けるか）。文言はこのファイルの 1 か所に置く（shared-dec-42）。
//

import SwiftUI

struct ResumeChoiceModifier: ViewModifier {
    @ObservedObject var vm: PodcastViewModel
    /// ミニとフルのうち、この画面が確認を出すか。同じ状態に対して 1 つの画面だけが出す。
    let isActive: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "どちらの位置から続けますか",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: vm.resumeChoice
        ) { _ in
            Button("別の端末の位置から") { vm.resolveResume(.otherDevice) }
            Button("この端末の位置から") { vm.resolveResume(.thisDevice) }
        } message: { choice in
            Text("別の端末: \(Self.clock(choice.otherDeviceSeconds)) ／ この端末: \(Self.clock(choice.thisDeviceSeconds))")
        }
    }

    /// 閉じる操作（システムのキャンセル・外側のタップ）だけが `false` を書く。ボタンの action が先でも後でも選択が消えないよう、
    /// 閉じた通知は 1 回後ろへ送る（確認が既に解決済みなら `resolveResume(nil)` は何もしない）。
    private var isPresented: Binding<Bool> {
        Binding(
            get: { isActive && vm.resumeChoice != nil },
            set: { presented in
                guard !presented else { return }
                DispatchQueue.main.async { vm.resolveResume(nil) }
            })
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension View {
    func resumeChoiceDialog(_ vm: PodcastViewModel, isActive: Bool) -> some View {
        modifier(ResumeChoiceModifier(vm: vm, isActive: isActive))
    }
}
