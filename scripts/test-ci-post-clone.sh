#!/usr/bin/env bash
# 実値ファイルを持ち込まず、clone 後の設定生成と Xcode の読込を検証する。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/news-listen-ci-test.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
HOOK="$ROOT/NewsListenApp/ci_scripts/ci_post_clone.sh"
test -x "$HOOK" || fail 'clone 後の設定生成 hook が実行可能でない'
git -C "$ROOT" archive HEAD | tar -x -C "$FIXTURE"
mkdir -p "$FIXTURE/NewsListenApp/ci_scripts"
cp "$HOOK" "$FIXTURE/NewsListenApp/ci_scripts/"
HOOK="$FIXTURE/NewsListenApp/ci_scripts/ci_post_clone.sh"
CONFIG="$FIXTURE/NewsListenApp/Secrets.xcconfig"
export API_BASE_URL='https://api.example.com/v1'
export API_KEY='test-key_123+//=' PASSKEY_RP_ID='api.example.com'

# 作業ディレクトリに依存せず、通常の URL を xcconfig に変換する。
cd /
"$HOOK" > "$FIXTURE/hook.log" 2>&1 || fail '有効な環境変数で生成に失敗'
test -f "$CONFIG" || fail 'Secrets.xcconfig が生成されない'
test "$(stat -f '%Lp' "$CONFIG")" = 600 || fail '秘密情報ファイルの権限が 600 でない'
! grep -Fq "$API_KEY" "$FIXTURE/hook.log" || fail 'API_KEY がログに含まれる'
cp "$CONFIG" "$FIXTURE/expected.xcconfig"

# 手元の実値設定は、環境変数がなくてもそのまま保持する。
env -u API_BASE_URL -u API_KEY -u PASSKEY_RP_ID "$HOOK" \
  > "$FIXTURE/hook.log" 2>&1 || fail '既存設定がある場合に失敗する'
cmp -s "$CONFIG" "$FIXTURE/expected.xcconfig" || fail '既存設定を上書きした'
printf 'PASS: 既存設定を保持する\n'

expect_rejected() {
  local name=$1 value=$2
  rm -f "$CONFIG"
  if env "$name=$value" "$HOOK" > "$FIXTURE/hook.log" 2>&1; then
    fail "$name の不正な値を受理した"
  fi
  test ! -e "$CONFIG" || fail '検証失敗後に設定ファイルが残る'
  grep -Fq "$name" "$FIXTURE/hook.log" || fail '不足・不正な変数名が報告されない'
  if test -n "$value"; then
    ! grep -Fq -- "$value" "$FIXTURE/hook.log" || fail '不正な入力値をログに出した'
  fi
}

for name in API_BASE_URL API_KEY PASSKEY_RP_ID; do
  rm -f "$CONFIG"
  if env -u "$name" "$HOOK" > "$FIXTURE/hook.log" 2>&1; then
    fail "$name が未設定でも成功した"
  fi
  test ! -e "$CONFIG" || fail '未設定の場合に設定ファイルが残る'
  grep -Fq "$name" "$FIXTURE/hook.log" || fail '未設定の変数名が報告されない'
  expect_rejected "$name" ''
  expect_rejected "$name" $'private-value\nOTHER_SETTING = injected'
  expect_rejected "$name" $'private-value\rinjected'
  expect_rejected "$name" '$(inherited)'
done
expect_rejected API_KEY 'private/*comment*/key'
expect_rejected API_KEY 'private key'
expect_rejected API_KEY 'private"key'
expect_rejected API_BASE_URL 'ftp://api.example.com'
expect_rejected PASSKEY_RP_ID 'https://api.example.com'
printf 'PASS: 未指定・不正値は値を出力せず拒否する\n'
"$HOOK" > "$FIXTURE/hook.log" 2>&1
for configuration in Debug Release; do
  xcodebuild -project "$FIXTURE/NewsListenApp/NewsListenApp.xcodeproj" \
    -scheme NewsListenApp -configuration "$configuration" \
    -derivedDataPath "$FIXTURE/DerivedData" -showBuildSettings \
    > "$FIXTURE/$configuration.log" 2>&1 || fail "$configuration の設定読込に失敗"
  for name in API_BASE_URL API_KEY PASSKEY_RP_ID; do
    grep -Fq "    $name = ${!name}" "$FIXTURE/$configuration.log" \
      || fail "$configuration で $name が正しく展開されない"
  done
done
printf 'PASS: clone 後に Debug / Release の必須設定を読み込める\n'
