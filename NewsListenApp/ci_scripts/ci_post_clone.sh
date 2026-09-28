#!/bin/bash
# Base Configuration の読込より前に Xcode Cloud の環境変数を設定ファイルへ渡す。
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIG="$PROJECT_DIR/Secrets.xcconfig"
# ローカルでの手動実行が既存の秘密情報を上書きしないようにする。
if [[ -e "$CONFIG" ]]; then
  exit 0
fi

# xcconfig の変数展開・複数行・コメント注入を防ぎ、値はエラーにも出さない。
for name in API_BASE_URL API_KEY PASSKEY_RP_ID; do
  value=${!name:-}
  case "$name" in
    API_BASE_URL) pattern='^https?://[A-Za-z0-9][A-Za-z0-9._~:/?@!&+,;=%#-]*$' ;;
    API_KEY) pattern='^[A-Za-z0-9_.+/=-]+$' ;;
    PASSKEY_RP_ID) pattern='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' ;;
  esac
  if [[ ! "$value" =~ $pattern ]]; then
    printf '必須環境変数 %s が未指定、または使用できない形式です。\n' "$name" >&2
    exit 1
  fi
done

umask 077
SLASH='/$()'
# URL と base64 形式のキーに含まれる // をコメントとして解釈させない。
printf 'API_BASE_URL = %s\nAPI_KEY = %s\nPASSKEY_RP_ID = %s\n' \
  "${API_BASE_URL//\//$SLASH}" "${API_KEY//\//$SLASH}" "$PASSKEY_RP_ID" > "$CONFIG"
