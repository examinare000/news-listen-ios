#!/usr/bin/env bash
# NewsListenApp のユニットテストをヘッドレス実行する。
# 使い方: ./scripts/test.sh        （SIMULATOR=<機種名> で機種を上書き可能）
# 例:     SIMULATOR='iPhone 16' ./scripts/test.sh
set -euo pipefail

cd "$(dirname "$0")/.."   # -> ios/

PROJECT="NewsListenApp/NewsListenApp.xcodeproj"
SCHEME="NewsListenApp"

# 使用シミュレータ機種。未指定なら利用可能な iPhone を自動選択。
DEVICE="${SIMULATOR:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices available | grep -oE 'iPhone [0-9][^(]*' | head -1 | sed 's/[[:space:]]*$//')
fi
if [ -z "$DEVICE" ]; then
  echo "利用可能な iPhone シミュレータが見つかりません。Xcode の Settings → Components で iOS ランタイムを追加してください。" >&2
  exit 1
fi
echo "==> Testing on simulator: $DEVICE"

# 既存の結果バンドルがあると xcodebuild が失敗するため削除。
rm -rf build/TestResults.xcresult

CMD=(xcodebuild test
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "platform=iOS Simulator,name=$DEVICE"
  -only-testing:NewsListenAppTests
  -resultBundlePath build/TestResults.xcresult)

if command -v xcbeautify >/dev/null 2>&1; then
  "${CMD[@]}" | xcbeautify
else
  "${CMD[@]}"
fi
