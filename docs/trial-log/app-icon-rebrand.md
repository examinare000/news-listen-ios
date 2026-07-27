# App Icon Rebrand — 実装記録

**2026-07-27 10:11** — アプリアイコン差し替え実装

## 内容
iOS アプリのアイコン資産を生成済みの承認版に差し替え、asset catalog 設定を更新。

### 実施内容
1. **AppIcon-1024.png 上書き**: スクラッチパッドの `/scratchpad/assets/AppIcon-1024.png`（1024² RGB 不透明）で差し替え
2. **AppIcon-1024-tinted.png 追加**: スクラッチパッドの `/scratchpad/assets/AppIcon-1024-tinted.png`（1024² RGBA 透過グレースケール）を新規コピー
3. **Contents.json 編集**: iOS tinted エントリ（line 20-31）に `"filename": "AppIcon-1024-tinted.png"` を追加
   - iOS dark エントリ（line 9-19）は filename 未設定のまま維持
   - mac エントリ 10 個（line 32-81）もそのまま維持
4. **ビルド検証**: `xcodebuild` シミュレータ向けビルドで asset catalog コンパイル成功を確認

### ファイル変更
```
 M NewsListenApp/NewsListenApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
 M NewsListenApp/NewsListenApp/Assets.xcassets/AppIcon.appiconset/Contents.json
?? NewsListenApp/NewsListenApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024-tinted.png
```

### ビルド結果
```
** BUILD SUCCEEDED **
```
- xctest は実行されず（asset catalog 処理のみ）
- 警告なし
- objectVersion 77（FileSystemSynchronizedRootGroup）により pbxproj 自動更新（手動編集不要）

## 試行と棄却
なし

---

**2026-07-27 追記** — 外観検証の実施状況（計画からの逸脱記録）

計画は「iOS 18+ シミュレータで any / dark / tinted の3外観を目視」を採否ゲートとしていたが、実施できたのは以下まで:

- **any**: iPhone 16 Pro (iOS 18.2) シミュレータのホーム画面で新アイコン表示を目視確認（白角なし・マスク正常）
- **dark**: dark スロットは意図的に filename 未設定（any フォールバック）のため、any と同一表示。独立の検証対象は存在しない
- **tinted**: `simctl` にホーム画面の着色モード切替APIが無く、実レンダリングは撮影不可。代替として Apple の合成方式（darkプレート＋グレースケール前景×tint乗算）を再現した合成プレビューを暖色/寒色の2色で生成し、**透過背景のため背景ごと着色される破綻は構造的に起きない**こと、シルエットが判読可能なことを確認した。`Assets.car` への `ISAppearanceTintable` 収録も `assetutil` で実測済み
- 最終確認は TestFlight/実機での目視に委ねる。万一破綻していた場合の是正は Contents.json の tinted エントリから filename を外す1行（追加コミット）
