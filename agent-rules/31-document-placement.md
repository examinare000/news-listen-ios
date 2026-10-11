# 31. 文書の置き場（親リポ `news-listen` の `docs/` を正本にする）

## 規則 🟠

- このリポジトリ（`ios`）には文書を置かない。対象は Implementation Spec・設計レビュー・takt の order・trial-log・ADR・調査レポートなど、`30-documentation-management.md` が `docs/` 配下に置くとしている文書の全部。
- 文書の正本は親リポ `news-listen` の `docs/`（private な docs サブモジュール）。置き場は親の `docs/README.md`「module の文書の置き場」に従う。
  - Implementation Spec: `docs/design/modules/ios/`
  - 設計レビュー: `docs/research-reports/ios/`
  - takt の order: `docs/plan/<計画の名前>/ios/`
  - trial-log: `docs/trial-log/ios-<論点>.md`
- このモジュールで作業するとき、`30-documentation-management.md` などの共通ルールが書く `docs/…` は、親リポの `docs/` を指すと読む（本ルールが置き場について 30 を上書きする）。
- コードやテストのコメント、このリポジトリのファイルから文書を指すときは、親リポ root からのパス（例: `docs/design/modules/ios/…`）で書く。

## 理由

`ios` は public リポジトリなので、設計判断・進捗・事業に関わる記述を置くと公開される。2026-10-03 に、各サブモジュールの `docs/` を親の `docs/` へ集約した。

---
**適用優先度**: 🟠 高
