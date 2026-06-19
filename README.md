# NewsListen iOS

Tech News Podcast アプリの iOS クライアント（SwiftUI / MVVM）。

## 実装状況

実装プランは親リポジトリの [`docs/superpowers/plans/2026-05-31-ios-app.md`](https://github.com/examinare000/news-listen/blob/main/docs/superpowers/plans/2026-05-31-ios-app.md) を参照。

| 領域 | 状況 | 備考 |
| --- | --- | --- |
| データモデル（Article / Podcast / RssSource） | ✅ 実装済み | |
| API クライアント（APIClient / APIEndpoint） | ✅ 実装済み | |
| AppState・エントリポイント | ✅ 実装済み | |
| Feed タブ | ✅ 実装済み | 一覧・スワイプ・Safari 表示 |
| Podcast タブ | ✅ 実装済み | 一覧・AVPlayer 再生・速度調整 |
| Settings タブ | ✅ 実装済み | 記事の開き方・RSS ソース管理・デフォルト難易度・再生速度・API 設定（[#7](https://github.com/examinare000/news-listen-ios/issues/7)） |
| 実機テスト | ⬜ 未着手 | |

ユニットテスト（Model / APIClient / Feed / Podcast / Settings）は実装済み。実機テストは未実施。

## セットアップ

1. 秘密情報設定ファイルを用意:
   ```sh
   cd NewsListenApp
   cp Secrets.example.xcconfig Secrets.xcconfig
   ```
   `Secrets.xcconfig` に `API_KEY` と `API_BASE_URL` を記入する（実ファイルは .gitignore 済み・コミット禁止）。
   URL の `://` は xcconfig のコメント回避のため `$()` でエスケープする（例: `http:/$()/localhost:8080`）。

2. Xcode で配線（初回のみ）:
   - Project → Info → Configurations で、App ターゲットの Debug / Release の **Base Configuration** を `Secrets.xcconfig` に設定。
   - App ターゲットの Build Settings で **`Info.plist File` = `Info.plist`**（プロジェクト直下。`GENERATE_INFOPLIST_FILE` は YES のまま）。
     ※ `Info.plist` は同期グループ（`NewsListenApp/` ソースフォルダ）の外（`.xcodeproj` と同階層）に置く。フォルダ内だとリソースとして二重コピーされ "Multiple commands produce Info.plist" になるため。
   - Product → Scheme → Manage Schemes で `NewsListenApp` スキームの **Shared** をチェック。

`Secrets.xcconfig` に値があれば初回設定画面はスキップされ、起動後すぐタブ画面になる。

## テスト

```sh
make test
# または機種指定
SIMULATOR='iPhone 16' ./scripts/test.sh
```

`NewsListenAppTests`（ユニットテスト）をシミュレータでヘッドレス実行する。UI テストは対象外。
