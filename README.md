# NewsListen iOS

Tech News Podcast アプリの iOS クライアント（SwiftUI / MVVM）。

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
   - App ターゲットの Build Settings で **`Info.plist File` = `NewsListenApp/Info.plist`**。
   - Product → Scheme → Manage Schemes で `NewsListenApp` スキームの **Shared** をチェック。

`Secrets.xcconfig` に値があれば初回設定画面はスキップされ、起動後すぐタブ画面になる。

## テスト

```sh
make test
# または機種指定
SIMULATOR='iPhone 16' ./scripts/test.sh
```

`NewsListenAppTests`（ユニットテスト）をシミュレータでヘッドレス実行する。UI テストは対象外。
