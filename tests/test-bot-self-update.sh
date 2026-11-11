#!/usr/bin/env bash
# Tests only UI/routing. No system changes, downloads, Telegram calls or service operations.
# shellcheck disable=SC1090,SC1091,SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AX_UNIT_TEST=1 source "$ROOT/autoxray"

latest_ax() { printf '%s\n' "${FAKE_LATEST:-3.14.5}"; }

assert_contains() { [[ $1 == *"$2"* ]] || { printf 'FAIL: expected substring %q\n' "$2"; exit 1; }; }

# The next release must be computed from installed AX_VERSION, never pinned to
# the next release: CI also runs after an upstream version bump.
IFS=. read -r version_major version_minor version_patch <<<"$AX_VERSION"
NEXT_VERSION="$version_major.$version_minor.$((version_patch + 1))"
FOLLOWING_VERSION="$version_major.$version_minor.$((version_patch + 2))"

FAKE_LATEST=$NEXT_VERSION
[[ $(bot_available_update) == "$NEXT_VERSION" ]]
kb=$(bot_status_kb)
[[ $(jq -r '.inline_keyboard[-1][0].callback_data' <<<"$kb") == "upd:ask:$NEXT_VERSION" ]]
[[ $(jq -r '.inline_keyboard | length' <<<"$kb") -eq 3 ]]

FAKE_LATEST=$AX_VERSION
[[ -z $(bot_available_update) ]]
kb=$(bot_status_kb)
[[ $(jq -r '.inline_keyboard | length' <<<"$kb") -eq 2 ]]

FAKE_LATEST=0.0.1
[[ -z $(bot_available_update) ]]

FAKE_LATEST='4.0.0;touch /tmp/pwned'
[[ -z $(bot_available_update) ]]

FAKE_LATEST=$NEXT_VERSION
TG_MSG=''; TG_KB=''; LAUNCH_LOG=$(mktemp)
trap 'rm -f "$LAUNCH_LOG"' EXIT
# Never make actual Telegram calls, or invoke systemd in this test.
tg_send() { TG_MSG=$2; TG_KB=${3:-}; }
systemd-run() { printf '%s\n' "$*" >>"$LAUNCH_LOG"; return 0; }

bot_update_prompt 10001 "$NEXT_VERSION"
assert_contains "$TG_MSG" "$AX_VERSION"
assert_contains "$TG_MSG" "$NEXT_VERSION"
[[ $TG_MSG == *$'\n'* ]]
[[ $(jq -r '.inline_keyboard[0][0].callback_data' <<<"$TG_KB") == "upd:do:$NEXT_VERSION" ]]

bot_update_start 10001 "$NEXT_VERSION"
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Запущено обновление'

bot_update_start 10001 '3.14.5;evil'
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Версия изменилась'

FAKE_LATEST=$FOLLOWING_VERSION
bot_update_start 10001 "$NEXT_VERSION"
[[ $(wc -l <"$LAUNCH_LOG") -eq 1 ]]
assert_contains "$TG_MSG" 'Версия изменилась'

printf 'OK: Telegram self-update UI, confirmation, stale version, validation, detached dispatch\n'

# All release-managed installed files must match the manifest of the current
# official release. A modified template or Telegram component must block update.
FIXTURE=$(mktemp -d)
trap 'if [[ -n ${LOCK_HOLDER_PID:-} ]]; then kill "$LOCK_HOLDER_PID" 2>/dev/null || true; fi; rm -rf "$FIXTURE" "$LAUNCH_LOG"' EXIT
AX_BIN="$FIXTURE/autoxray"
TPL_DIR="$FIXTURE/share"
AX_ETC="$FIXTURE/etc"
SNAP_DIR="$FIXTURE/snapshots"
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
bot_update_original_is_pristine || { echo 'FAIL: restored installation rejected'; exit 1; }
printf 'OK: all release-managed files protected from overwrite\n'

# The shared lock must protect the full update and be released on return.
# No update is performed in this test.
need_root() { :; }
assert_lock_held() {
  if flock -n "$SNAP_DIR/.update.lock" -c true; then
    echo 'FAIL: common update lock was not held'; return 1
  fi
}
with_update_lock assert_lock_held
# Verify that CLI update and worker routes use the lock without invoking
# real downloads, systemd or replacing any files.
cmd_self_update() { assert_lock_held; }
bot_update_worker() { assert_lock_held; }
main self-update
main bot-update-worker

# Exercise the REAL cmd_rollback with a dummy snapshot and a stub restore.
# This proves that rollback cannot get as far as restoring files when an
# update holds the same lock, without writing to the host filesystem.
: >"$SNAP_DIR/fixture.tar.gz"
RESTORE_LOG="$FIXTURE/restore.log"
: >"$RESTORE_LOG"
confirm() { return 0; }
snapshot_restore() {
  assert_lock_held || return 1
  printf '%s\n' "$1" >>"$RESTORE_LOG"
}
main rollback 1
[[ $(wc -l <"$RESTORE_LOG") -eq 1 ]] || {
  echo 'FAIL: unlocked rollback did not restore the fixture'; exit 1
}

# Check BOTH TUI rollback entry points and its update entry point.
grep -Fq '0) (with_update_lock cmd_self_update); pause ;;' "$ROOT/autoxray" || {
  echo 'FAIL: TUI bypasses update lock'; exit 1
}
[[ $(grep -Fc '3) (with_update_lock cmd_rollback); pause ;;' "$ROOT/autoxray") -eq 2 ]] || {
  echo 'FAIL: a TUI rollback path bypasses the lock'; exit 1
}
flock -n "$SNAP_DIR/.update.lock" -c true || {
  echo 'FAIL: maintenance lock was not released'; exit 1
}

# Hold the lock in ANOTHER process, with explicit synchronization rather
# than timing-based sleeps. CLI update and manual rollback must both refuse
# to run while that process holds it.
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
if (main bot-update-worker 10001 >/dev/null 2>&1); then
  echo 'FAIL: concurrent Telegram update was accepted'; exit 1
fi
if (main rollback 1 >/dev/null 2>&1); then
  echo 'FAIL: concurrent CLI rollback was accepted'; exit 1
fi
[[ $(wc -l <"$RESTORE_LOG") -eq 1 ]] || {
  echo 'FAIL: rollback restored files while maintenance lock was busy'; exit 1
}
printf 'release\n' >"$LOCK_RELEASE"
wait "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=''
# Lock must become available again after competing update/rollback exits.
main rollback 1
[[ $(wc -l <"$RESTORE_LOG") -eq 2 ]] || {
  echo 'FAIL: rollback did not recover after lock became free'; exit 1
}
flock -n "$SNAP_DIR/.update.lock" -c true || {
  echo 'FAIL: maintenance lock leaked after rollback'; exit 1
}
printf 'OK: CLI/Telegram updates and both TUI/CLI rollback paths share maintenance lock\n'
