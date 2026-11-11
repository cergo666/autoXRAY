#!/usr/bin/env bash
# Tests Telegram dispatch, worker checks and locking without privileges or real services.
# shellcheck disable=SC1090,SC1091,SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE=$(mktemp -d)
cleanup() {
  local pid
  for pid in "${LOCK_HOLDER_PID:-}" "${BG_CHILD_PID:-}"; do
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
  done
  rm -rf "$FIXTURE"
}
trap cleanup EXIT
export AX_DRY=1
export AX_ETC="$FIXTURE/etc" AX_SNAP_DIR="$FIXTURE/snapshots" AX_BIN="$FIXTURE/installed-autoxray"
export AX_TEMPLATES="$FIXTURE/share" AX_BOT_UPDATE_LOG_DIR="$FIXTURE/logs"
mkdir -p "$AX_ETC"
printf '%s\n' '{"bot":{"enabled":true,"admins":[10001,10002]},"users":[{"name":"client","tg":10003}]}' >"$AX_ETC/state.json"
printf '%s\n' test-token >"$AX_ETC/bot.token"
AX_UNIT_TEST=1 source "$ROOT/autoxray"

latest_ax() { printf '%s\n' "$FAKE_LATEST"; }
assert_contains() { [[ $1 == *"$2"* ]] || { printf 'FAIL: expected substring %q in %q\n' "$2" "$1"; exit 1; }; }

IFS=. read -r version_major version_minor version_patch <<<"$AX_VERSION"
NEXT_VERSION="$version_major.$version_minor.$((10#$version_patch + 1))"
FOLLOWING_VERSION="$version_major.$version_minor.$((10#$version_patch + 2))"

FAKE_LATEST=$NEXT_VERSION
[[ $(bot_available_update) == "$NEXT_VERSION" ]]
kb=$(bot_status_kb)
[[ $(jq -r '.inline_keyboard[-1][0].callback_data' <<<"$kb") == "upd:ask:$NEXT_VERSION" ]]
[[ $(jq -r '.inline_keyboard | length' <<<"$kb") -eq 3 ]]

for FAKE_LATEST in "$AX_VERSION" 0.0.0 "$NEXT_VERSION;invalid"; do
  [[ -z $(bot_available_update) ]]
  kb=$(bot_status_kb)
  [[ $(jq -r '.inline_keyboard | length' <<<"$kb") -eq 2 ]]
done

FAKE_LATEST=$NEXT_VERSION
TG_MSG=''; TG_KB=''; LAUNCH_LOG="$FIXTURE/launch.log"
: >"$LAUNCH_LOG"
tg_send() { TG_MSG=$2; TG_KB=${3:-}; }
tg_answer() { :; }
systemd-run() { printf '%s\n' "$*" >>"$LAUNCH_LOG"; return "${FAKE_LAUNCH_RC:-0}"; }

callback() {
  local update
  update=$(jq -nc --argjson user "$1" --argjson chat "$2" --arg type "$3" --arg data "$4" '
    {callback_query:{id:"cb",from:{id:$user},data:$data,message:{message_id:1,chat:{id:$chat,type:$type}}}}')
  bot_handle_update "$update"
}

bot_handle_update '{"message":{"from":{"id":10001},"chat":{"id":10001,"type":"private"},"text":"/update"}}'
assert_contains "$TG_MSG" "$AX_VERSION"
assert_contains "$TG_MSG" "$NEXT_VERSION"
[[ $TG_MSG == *$'\n'* ]]
confirm_data=$(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB")
[[ $confirm_data =~ ^upd:do:[0-9a-f]{32}$ ]]

callback 999 999 private "$confirm_data"
callback 10003 10003 private "$confirm_data"
callback 10001 -123 group "$confirm_data"
callback 10002 10002 private "$confirm_data"
callback 10001 10001 private "upd:do:$NEXT_VERSION"
assert_contains "$TG_MSG" 'Подтверждение недействительно'
[[ ! -s $LAUNCH_LOG ]]

callback 10001 10001 private "$confirm_data"
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$(cat "$LAUNCH_LOG")" "$AX_BIN bot-update-worker 10001 $AX_VERSION $NEXT_VERSION"
assert_contains "$(cat "$LAUNCH_LOG")" '--property=Type=exec'
assert_contains "$TG_MSG" 'Запущено обновление'
callback 10001 10001 private "$confirm_data"
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Подтверждение недействительно'

callback 10001 10001 private "upd:ask:$NEXT_VERSION"
confirm_data=$(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB")
cancel_data=$(jq -r '.inline_keyboard[0][1].callback_data' <<<"$TG_KB")
callback 10001 10001 private "$cancel_data"
assert_contains "$TG_MSG" 'Обновление отменено'
callback 10001 10001 private "$confirm_data"
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]

callback 10001 10001 private "upd:ask:$NEXT_VERSION"
confirm_data=$(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB")
sed -i 's/ [0-9]*$/ 0/' "$UPDATE_CONFIRM_DIR/10001"
callback 10001 10001 private "$confirm_data"
assert_contains "$TG_MSG" 'подтверждение устарело'
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]

callback 10001 10001 private "upd:ask:$NEXT_VERSION"
confirm_data=$(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB")
FAKE_LATEST=$FOLLOWING_VERSION
callback 10001 10001 private "$confirm_data"
assert_contains "$TG_MSG" 'Версия изменилась'
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]

FAKE_LATEST=$NEXT_VERSION
callback 10001 10001 private "upd:ask:$NEXT_VERSION"
confirm_data=$(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB")
FAKE_LAUNCH_RC=1 callback 10001 10001 private "$confirm_data" 2>"$FIXTURE/dispatch-error"
assert_contains "$TG_MSG" 'Не удалось запустить задачу'
assert_contains "$(cat "$FIXTURE/dispatch-error")" 'Не удалось запустить autoxray-bot-update'
printf 'OK: authorized private chat, one-time confirmation, cancel, expiry, stale version, detached dispatch and launch failure\n'

(
  mock_live() { printf '{"tag_name":"v%s"}\n' "$FAKE_LATEST"; }
  CURL=mock_live
  cmd_self_update() { printf '%s\n' "$@" >>"$FIXTURE/worker-calls"; return "${FAKE_UPDATE_RC:-0}"; }
  if (bot_update_worker 999 "$AX_VERSION" "$NEXT_VERSION") >/dev/null 2>&1; then
    echo 'FAIL: worker accepted a non-admin'; exit 1
  fi
  if bot_update_worker 10001 "$FOLLOWING_VERSION" "$NEXT_VERSION"; then
    echo 'FAIL: worker accepted a different installed version'; exit 1
  fi
  assert_contains "$TG_MSG" 'Установленная версия изменилась'
  FAKE_LATEST=$FOLLOWING_VERSION
  if bot_update_worker 10001 "$AX_VERSION" "$NEXT_VERSION"; then
    echo 'FAIL: worker accepted an outdated release'; exit 1
  fi
  assert_contains "$TG_MSG" 'Релиз не удалось проверить'
  [[ ! -e $FIXTURE/worker-calls ]]
  FAKE_LATEST=$NEXT_VERSION
  bot_update_worker 10001 "$AX_VERSION" "$NEXT_VERSION"
  assert_contains "$TG_MSG" "обновлён до $NEXT_VERSION"
  [[ $(cat "$FIXTURE/worker-calls") == "$(printf 'v%s\n10001' "$NEXT_VERSION")" ]]
  for rc in 1 78; do
    result=0
    FAKE_UPDATE_RC=$rc bot_update_worker 10001 "$AX_VERSION" "$NEXT_VERSION" || result=$?
    [[ $result == "$rc" ]]
    if [[ $rc == 78 ]]; then assert_contains "$TG_MSG" 'до установки'
    else assert_contains "$TG_MSG" 'не удалось'; fi
  done
  logs=("$BOT_UPDATE_LOG_DIR"/*.log)
  [[ ${#logs[@]} == 3 && $(stat -c %a "$BOT_UPDATE_LOG_DIR") == 700 ]]
  for log in "${logs[@]}"; do [[ $(stat -c %a "$log") == 600 ]]; done
)
(
  AX_UNIT_TEST=1 source "$ROOT/autoxray"
  tg_call() { printf '%s\n' '{"ok":false,"error_code":429}'; }
  if tg_send 10001 test; then echo 'FAIL: Telegram API error treated as delivered'; exit 1; fi
  tg_call() { printf '%s\n' '{"ok":true}'; }
  tg_send 10001 test
)
printf 'OK: worker authorization, pinned versions, protected logs, result and Telegram API errors\n'

# All release-managed installed files must match the manifest of the current
# official release. A modified template or Telegram component must block update.
mkdir -p "$TPL_DIR/telegram" "$AX_ETC"
SUMS_FILE="$FIXTURE/FILES.sha256"
: >"$SUMS_FILE"
for file in "${RELEASE_FILES[@]}"; do
  case $file in
    autoxray) installed=$AX_BIN ;;
    templates/*) installed="$TPL_DIR/${file#templates/}" ;;
    components/telegram/*) installed="$TPL_DIR/telegram/${file#components/telegram/}" ;;
    *) echo "FAIL: unknown release file $file"; exit 1 ;;
  esac
  cp "$ROOT/$file" "$installed"
  printf '%s  %s\n' "$(sha256sum "$installed" | awk '{print $1}')" "$file" >>"$SUMS_FILE"
done
mockcurl() { cat "$SUMS_FILE"; }
CURL=mockcurl
bot_update_original_is_pristine || { echo 'FAIL: clean installation rejected'; exit 1; }

printf '\n' >>"$AX_BIN"
if bot_update_original_is_pristine; then
  echo 'FAIL: changed main script was not detected'; exit 1
fi
cp "$ROOT/autoxray" "$AX_BIN"

printf '\n' >>"$TPL_DIR/sub.html"
if bot_update_original_is_pristine; then
  echo 'FAIL: changed template was not detected'; exit 1
fi
cp "$ROOT/templates/sub.html" "$TPL_DIR/sub.html"

printf '\n' >>"$TPL_DIR/telegram/install.sh"
if bot_update_original_is_pristine; then
  echo 'FAIL: changed Telegram component was not detected'; exit 1
fi
cp "$ROOT/components/telegram/install.sh" "$TPL_DIR/telegram/install.sh"

mv "$TPL_DIR/telegram/artifacts.sh" "$TPL_DIR/telegram/artifacts.sh.bak"
if bot_update_original_is_pristine; then
  echo 'FAIL: missing component was not detected'; exit 1
fi
mv "$TPL_DIR/telegram/artifacts.sh.bak" "$TPL_DIR/telegram/artifacts.sh"

printf '%s  autoxray\n' "$(sha256sum "$AX_BIN" | awk '{print $1}')" >>"$SUMS_FILE"
if bot_update_original_is_pristine; then
  echo 'FAIL: duplicate manifest entry was not detected'; exit 1
fi
sed -i '$d' "$SUMS_FILE"
sed -i '/  autoxray$/s/$/ extra/' "$SUMS_FILE"
if bot_update_original_is_pristine; then
  echo 'FAIL: malformed manifest entry was not detected'; exit 1
fi
sed -i 's/  autoxray extra$/  autoxray/' "$SUMS_FILE"
bot_update_original_is_pristine || { echo 'FAIL: restored installation rejected'; exit 1; }
printf 'OK: all release-managed files protected from overwrite\n'

# Real flock supervisor regression. Run command handlers in a fresh shell,
# just like production. An external `flock --close` retains the lock only in its
# supervisor process, never in the update shell or its background descendants.
# Substitute harmless service/restore functions in a COPY of the source to
# exercise the real dispatcher and rollback selector without touching the host.
TEST_DRIVER="$FIXTURE/test-driver.sh"
cp "$ROOT/autoxray" "$TEST_DRIVER"
cat >>"$TEST_DRIVER" <<'BASH'
assert_lock_held() {
  if flock -n "$SNAP_DIR/.update.lock" -c true; then
    echo 'FAIL: common update lock was not held'; return 1
  fi
}
cmd_self_update() {
  assert_lock_held || return 1
  if [[ ${AX_TEST_UPDATE_BG:-0} == 1 ]]; then
    spawn_background_child
  fi
}
maintenance_failure() {
  assert_lock_held || return 1
  return 37
}
bot_update_worker() { assert_lock_held; }
confirm() { return 0; }
snapshot_restore() {
  assert_lock_held || return 1
  printf '%s\n' "$1" >>"$AX_MAINTENANCE_RESTORE_LOG"
}
spawn_background_child() {
  assert_lock_held || return 1
  sleep 15 >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$AX_MAINTENANCE_BG_PID"
}
BASH
chmod +x "$TEST_DRIVER"
mkdir -p "$SNAP_DIR"
: >"$SNAP_DIR/fixture.tar.gz"
RESTORE_LOG="$FIXTURE/restore.log"
: >"$RESTORE_LOG"
AX_UNIT_TEST=1 source "$TEST_DRIVER"
export AX_MAINTENANCE_RESTORE_LOG="$RESTORE_LOG"
export AX_MAINTENANCE_BG_PID="$FIXTURE/background.pid"

with_update_lock assert_lock_held
main self-update
main bot-update-worker 10001 "$AX_VERSION" "$NEXT_VERSION"
main rollback 1
[[ $(wc -l <"$RESTORE_LOG") -eq 1 ]] || {
  echo 'FAIL: unlocked rollback did not restore the fixture'; exit 1
}

# Drive each TUI entry through its normal menu and record dispatch to the lock.
(
  clear() { :; }
  xray_version() { :; }
  pause() { :; }
  choose() { CHOICE=$selection; selection=$back; }
  with_update_lock() { printf '%s\n' "$1" >>"$FIXTURE/menu-calls"; }
  selection=0; back=4; menu_update
  selection=3; back=4; menu_update
  selection=3; back=6; menu_maint
  [[ $(cat "$FIXTURE/menu-calls") == $'cmd_self_update\ncmd_rollback\ncmd_rollback' ]]
) >"$FIXTURE/menu.out" || { echo 'FAIL: a TUI entry bypassed the update lock'; exit 1; }
flock -n "$SNAP_DIR/.update.lock" -c true || {
  echo 'FAIL: maintenance lock was not released'; exit 1
}

# Regression: update starts a background subprocess; it is STILL RUNNING
# after update returns, but it must NOT hold the lock. This exact scenario
# previously prevented immediate rollback after a successful update.
export AX_TEST_UPDATE_BG=1
main self-update
unset AX_TEST_UPDATE_BG
BG_CHILD_PID=$(cat "$AX_MAINTENANCE_BG_PID")
kill -0 "$BG_CHILD_PID" 2>/dev/null || {
  echo 'FAIL: background child exited too early'; exit 1
}
flock -n "$SNAP_DIR/.update.lock" -c true || {
  echo 'FAIL: background child inherited maintenance lock'; exit 1
}
main rollback 1
[[ $(wc -l <"$RESTORE_LOG") -eq 2 ]] || {
  echo 'FAIL: immediate rollback after background child was blocked'; exit 1
}
kill "$BG_CHILD_PID" 2>/dev/null || true
BG_CHILD_PID=''
# Even a failed maintenance command must release the supervisor lock.
rc=0
with_update_lock maintenance_failure >/dev/null 2>&1 || rc=$?
[[ $rc == 37 ]] || { echo "FAIL: wrong maintenance exit code: $rc"; exit 1; }
flock -n "$SNAP_DIR/.update.lock" -c true || {
  echo 'FAIL: maintenance failure leaked lock'; exit 1
}
printf 'OK: background subprocess cannot retain the update/rollback lock\n'

# Lock contention with another process must reject CLI update, Telegram
# update and manual rollback, and must never enter snapshot_restore.
LOCK_READY="$FIXTURE/lock-ready"
LOCK_RELEASE="$FIXTURE/lock-release.fifo"
mkfifo "$LOCK_RELEASE"
(
  exec 55>"$SNAP_DIR/.update.lock"
  flock -n 55 || exit 1
  : >"$LOCK_READY"
  IFS= read -r _ <"$LOCK_RELEASE"
) &
LOCK_HOLDER_PID=$!
for ((tries=0; tries<200; tries++)); do
  [[ -f $LOCK_READY ]] && break
  sleep 0.02
done
[[ -f $LOCK_READY ]] || { echo 'FAIL: competing lock holder did not start'; exit 1; }
if (main self-update >/dev/null 2>&1); then
  echo 'FAIL: concurrent CLI update was accepted'; exit 1
fi
if (main bot-update-worker 10001 "$AX_VERSION" "$NEXT_VERSION" >/dev/null 2>&1); then
  echo 'FAIL: concurrent Telegram update was accepted'; exit 1
fi
if (main rollback 1 >/dev/null 2>&1); then
  echo 'FAIL: concurrent CLI rollback was accepted'; exit 1
fi
[[ $(wc -l <"$RESTORE_LOG") -eq 2 ]] || {
  echo 'FAIL: rollback restored files while maintenance lock was busy'; exit 1
}
printf 'release\n' >"$LOCK_RELEASE"
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=''
main rollback 1
[[ $(wc -l <"$RESTORE_LOG") -eq 3 ]] || {
  echo 'FAIL: rollback did not recover after lock became free'; exit 1
}
flock -n "$SNAP_DIR/.update.lock" -c true || {
  echo 'FAIL: maintenance lock leaked after rollback'; exit 1
}
printf 'OK: CLI/Telegram update and manual rollback share non-leaking maintenance lock\n'
