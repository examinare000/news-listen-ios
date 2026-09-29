# ScriptedURLSession の lost wakeup（CI 6 時間ハング）

- 日付: 2026-09-30
- 判定: 解決（ハーネス修正＋CI ジョブ上限）

## 観測
- ios PR #92（Swift 警告 2 件の修正、挙動変更なし）の `ios-test` が 6 時間の既定上限で cancel（run 36511216822）。
  `AppStateAuthTests.testTT14_18_outerCancellationDoesNotCancelPreferencesSync` が started のまま止まっていた。main では同テストが 0.005 秒で pass。
- ローカル（Xcode 26.6 / iPhone 17 Pro シミュレータ）でも、新規の契約テスト `ScriptedURLSessionTests.testReleaseImmediatelyAfterArrivalAlwaysResumesPendingRequest`（50 反復）が修正前に 7 時間ハングし再現した。

## 原因
`ScriptedURLSession.data(for:)` の `.pending` 経路で、到着通知（`waitUntilRequested` の待ち手を resume）と `pendingContinuations` への登録が別のロック区間だった。テストは到着通知の直後に `release` を呼ぶため、「到着通知 → release → 保留登録」の順に走ると `release` が保留無しとして捨て、後から登録された continuation は永遠に resume されない。`refreshPreferences` は非構造化 Task なので外側の cancel でも解放されない。

## 対応
1. `.pending` 経路では保留登録と到着通知を同一ロック区間で行う（`State.markArrived`）。`immediate` / 未設定の経路は従来どおり最初のロック区間で到着を記録する。`release` の「保留が無ければ何もしない」契約は不変。
2. 契約テスト `ScriptedURLSessionTests` を追加。timeout 時は Task を cancel してから await し、ハングを失敗に変換する（cancel せずに `await task.value` すると timeout 後も固まる。修正前の初版で実測）。
3. `.github/workflows/ci.yml` の `ios-test` に `timeout-minutes: 30`（main の実測 10 分の 3 倍）。

## 検証
- 修正後: `AppStateAuthTests` + `ScriptedURLSessionTests` を `-test-iterations 100 -run-tests-until-failure` で 4000 tests / 0 failures。

## 教訓
- 「到着を観測してから解放する」ハーネスは、到着通知と待受登録を同一の臨界区間に置く。分けた瞬間に lost wakeup の窓ができる。
- ハングを検知するテストは、timeout 後に必ず被験 Task を cancel してから await する。
- CI のジョブには `timeout-minutes` を付ける。付けないとハング 1 回で 6 時間ぶん runner を失う。
