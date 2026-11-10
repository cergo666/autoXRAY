#!/usr/bin/env bash
# Tests only UI/routing. No system changes, downloads, Telegram calls or service operations.
# shellcheck disable=SC1090,SC1091,SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AX_UNIT_TEST=1 source "$ROOT/autoxray"

latest_ax() { printf '%s\n' "${FAKE_LATEST:-3.14.5}"; }

assert_contains() { [[ $1 == *"$2"* ]] || { printf 'FAIL: expected substring %q\n' "$2"; exit 1; }; }

FAKE_LATEST=3.14.5
[[ $(bot_available_update) == 3.14.5 ]]
kb=$(bot_status_kb)
[[ $(jq -r '.inline_keyboard[-1][0].callback_data' <<<"$kb") == upd:ask:3.14.5 ]]
[[ $(jq -r '.inline_keyboard | length' <<<"$kb") -eq 3 ]]

FAKE_LATEST=3.14.4
[[ -z $(bot_available_update) ]]
kb=$(bot_status_kb)
[[ $(jq -r '.inline_keyboard | length' <<<"$kb") -eq 2 ]]

FAKE_LATEST=3.14.3
[[ -z $(bot_available_update) ]]

FAKE_LATEST='4.0.0;touch /tmp/pwned'
[[ -z $(bot_available_update) ]]

FAKE_LATEST=3.14.5
TG_MSG=''; TG_KB=''; LAUNCH_LOG=$(mktemp)
trap 'rm -f "$LAUNCH_LOG"' EXIT
# Never make actual Telegram calls, or invoke systemd in this test.
tg_send() { TG_MSG=$2; TG_KB=${3:-}; }
systemd-run() { printf '%s\n' "$*" >>"$LAUNCH_LOG"; return 0; }

bot_update_prompt 10001 3.14.5
assert_contains "$TG_MSG" '3.14.4'
assert_contains "$TG_MSG" '3.14.5'
[[ $TG_MSG == *$'\n'* ]]
[[ $(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB") == upd:do:3.14.5 ]]

bot_update_start 10001 3.14.5
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Запущено обновление'

bot_update_start 10001 '3.14.5;evil'
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Версия изменилась'

FAKE_LATEST=3.14.6
bot_update_start 10001 3.14.5
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Версия изменилась'

printf 'OK: Telegram self-update UI, confirmation, stale version, validation, detached dispatch\n'

# A locally modified main script must block automated updates before self-update.
AX_BIN=$(mktemp)
SUMS_FILE=$(mktemp)
cp "$ROOT/autoxray" "$AX_BIN"
printf '%s  autoxray\n' "$(sha256sum "$AX_BIN" | awk '{print $1}')" >"$SUMS_FILE"
mockcurl() { cat "$SUMS_FILE"; }
CURL=mockcurl
bot_update_original_is_pristine
printf '\n' >>"$AX_BIN"
if bot_update_original_is_pristine; then
  echo 'FAIL: local modification was not detected'
  rm -f "$AX_BIN" "$SUMS_FILE"
  exit 1
fi
rm -f "$AX_BIN" "$SUMS_FILE"
printf 'OK: local modifications prevent automatic updates\n'
