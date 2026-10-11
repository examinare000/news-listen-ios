# ios — CLAUDE.md

> Submodule (`news-listen-ios`). 親リポジトリ `news-listen` 配下で作業する場合、
> `../agent-rules/` のルールが正本。本ファイルはこのモジュール固有の補足のみ。

## スタック
- Swift / SwiftUI。Xcode プロジェクト: `NewsListenApp/NewsListenApp.xcodeproj`。
- テスト: `make test`（`./scripts/test.sh` 経由）。

## 作業規約
- TDD 必須（`agent-rules/11-testing-strategy.md`）。XCTest を実装前に書く。
- 認証・トークン管理は `agent-rules/12-security-guidelines.md` 準拠。Keychain を使い、ログに出さない。

## このモジュールで触らないこと
- `build/`・`*.bundle` 等のビルド生成物は手動編集しない。
