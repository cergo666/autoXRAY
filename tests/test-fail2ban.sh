#!/usr/bin/env bash
# Проверки установщика и Telegram-диспетчера с локальными заглушками.
# shellcheck disable=SC1091
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export AX_DRY=1 AX_ETC="$FIXTURE/state" AX_F2B_FIXTURE="$FIXTURE"
mkdir -p "$AX_ETC" "$FIXTURE/bin"
export PATH="$FIXTURE/bin:$PATH"
printf '%s\n' '{"bot":{"enabled":true,"admins":[10001,10002]},"users":[]}' >"$AX_ETC/state.json"
printf '%s\n' test-token >"$AX_ETC/bot.token"
AX_UNIT_TEST=1 source ./autoxray
F2B_RUN_DIR="$FIXTURE/run"

cat >"$FIXTURE/bin/curl" <<'SH'
#!/bin/sh
touch "$AX_F2B_FIXTURE/unexpected-curl"
exit 1
SH
cat >"$FIXTURE/bin/fail2ban-client" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$AX_F2B_FIXTURE"
printf '%s\n' "$*" >>client.log
[[ -e installed && ! -e unavailable ]] || exit 1
case $* in
  '-t') [[ ! -e invalid-config ]] ;;
  'status sshd')
    [[ -e active ]] || exit 1
    printf 'Status for the jail: sshd\n  Currently failed: 1\n  Total failed: 19\n  Currently banned: %s\n  Total banned: 29\n' "$(wc -l <bans)" ;;
  'get sshd banip') tr '\n' ' ' <bans ;;
  'get sshd banned '*)
    if [[ -e bad-reply ]]; then printf '%s\n' 'unexpected response'; exit 0; fi
    if grep -Fxq -- "$4" bans; then echo 1; else echo 0; fi ;;
  'set sshd unbanip '*)
    [[ $# == 4 ]] || exit 1
    printf '%s\n' "$4" >>unbans
    [[ ! -e unban-error ]] || exit 1
    if [[ ! -e still-banned ]]; then grep -Fxv -- "$4" bans >bans.next || true; mv -- bans.next bans; fi
    [[ ! -e unavailable-after-unban ]] || touch unavailable
    echo 1 ;;
  *) exit 1 ;;
esac
SH
cat >"$FIXTURE/bin/apt-get" <<'SH'
#!/bin/bash
set -euo pipefail
[[ $* == 'install -y --no-install-recommends fail2ban nftables python3-systemd' && $DEBIAN_FRONTEND == noninteractive ]]
[[ ! -e /proc/$$/fd/8 ]]
cd "$AX_F2B_FIXTURE"
printf '%s\n' "$*" >>apt.log
[[ ! -e apt-fails ]]
touch installed
SH
cat >"$FIXTURE/bin/sshd" <<'SH'
#!/bin/bash
[[ $* == -T ]] && cat "$AX_F2B_FIXTURE/sshd-config"
SH
cat >"$FIXTURE/bin/nft" <<'SH'
#!/bin/bash
[[ $* == 'list tables' && ! -e $AX_F2B_FIXTURE/nft-error ]]
SH
cat >"$FIXTURE/bin/systemctl" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$AX_F2B_FIXTURE"
printf '%s\n' "$*" >>systemctl.log
case $* in
  'is-active --quiet ssh.socket') [[ -f socket-listen ]] ;;
  'show --property=Listen --value ssh.socket') cat socket-listen ;;
  'restart fail2ban.service') [[ ! -e /proc/$$/fd/8 && ! -e restart-fails ]]; touch active ;;
  'is-active --quiet fail2ban.service') [[ -e active ]] ;;
  'enable fail2ban.service') [[ ! -e /proc/$$/fd/8 ]]; touch enabled ;;
  'disable --now fail2ban.service') [[ ! -e /proc/$$/fd/8 ]]; rm -f active enabled ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FIXTURE/bin/"*

# Управляем наличием пакета, чтобы тест также запускался на сервере с Fail2ban.
command() {
  if [[ $* == '-v fail2ban-client' && ! -e $FIXTURE/installed ]]; then return 1; fi
  builtin command "$@"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || { printf 'FAIL: expected %q in %q\n' "$2" "$1" >&2; exit 1; }
}

printf 'port 22\nlistenaddress [::]:2222\nlistenaddress 127.0.0.1:4444\nlistenaddress 0.0.0.0:2222\n' >"$FIXTURE/sshd-config"
[[ $(f2b_ssh_ports) == 2222,4444 ]]
printf '[::]:2022 (Stream)\n0.0.0.0:2022 (Stream)\n127.0.0.1:8022 (Stream)\n' >"$FIXTURE/socket-listen"
[[ $(f2b_ssh_ports) == 2022,8022 ]]
printf '[::]:65536 (Stream)\n' >"$FIXTURE/socket-listen"
if f2b_ssh_ports >/dev/null; then echo 'FAIL: invalid socket port accepted'; exit 1; fi
rm -- "$FIXTURE/socket-listen"
printf 'OK: actual SSH listen addresses, socket activation and invalid port rejection\n'

etc="$FIXTURE/etc"
jail="$etc/jail.d/90-autoxray-sshd.local"
server="$etc/fail2ban.d/90-autoxray.local"
touch "$FIXTURE/apt-fails"
if setup_fail2ban "$etc" >"$FIXTURE/setup.log" 2>&1; then echo 'FAIL: apt error ignored'; exit 1; fi
[[ ! -e $jail && ! -e $server && -d $etc/.autoxray-setup ]]
rm -- "$FIXTURE/apt-fails"
: >"$FIXTURE/bans"
( setup_fail2ban "$etc" ) 8>"$FIXTURE/test.lock" >"$FIXTURE/setup.log"
for setting in 'port = 2222,4444' 'maxretry = 3' 'findtime = 10m' 'bantime = 24h' 'bantime.increment = true' 'bantime.maxtime = 30d' \
    'backend = systemd' 'mode = aggressive' 'banaction = nftables[type=multiport,blocktype="tcp flags syn / syn,ack reject"]'; do grep -Fxq -- "$setting" "$jail"; done
grep -Fxq 'dbpurgeage = 2678400' "$server"
[[ $(stat -c %a "$jail") == 600 && -e $FIXTURE/enabled && ! -e $etc/.autoxray-setup ]]
printf 'OK: clean installation, exact policy, no inherited setup lock and retry after apt error\n'

printf '# local policy\n' >>"$jail"
before=$(sha256sum <"$jail")
apt_before=$(sha256sum <"$FIXTURE/apt.log")
systemctl_before=$(sha256sum <"$FIXTURE/systemctl.log")
setup_fail2ban "$etc" >/dev/null
rm -- "$FIXTURE/active"
if setup_fail2ban "$etc" >"$FIXTURE/inactive.log" 2>&1; then echo 'FAIL: inactive jail accepted'; exit 1; fi
[[ $(sha256sum <"$jail") == "$before" && $(sha256sum <"$FIXTURE/apt.log") == "$apt_before" ]]
[[ $(sha256sum <"$FIXTURE/systemctl.log") == "$systemctl_before" ]]
rm -- "$FIXTURE/installed" "$FIXTURE/enabled"
if setup_fail2ban "$etc" >"$FIXTURE/leftovers.log" 2>&1; then echo 'FAIL: residual policy overwritten'; exit 1; fi
[[ $(sha256sum <"$jail") == "$before" && $(sha256sum <"$FIXTURE/apt.log") == "$apt_before" ]]
printf 'OK: installed, inactive and residual custom configuration preserved\n'

etc="$FIXTURE/bad-etc"
jail="$etc/jail.d/90-autoxray-sshd.local"
server="$etc/fail2ban.d/90-autoxray.local"
touch "$FIXTURE/invalid-config"
if setup_fail2ban "$etc" >"$FIXTURE/invalid.log" 2>&1; then echo 'FAIL: invalid config accepted'; exit 1; fi
[[ ! -e $jail && ! -e $server && -e $FIXTURE/installed && ! -e $FIXTURE/enabled ]]
rm -- "$FIXTURE/invalid-config"
touch "$FIXTURE/restart-fails"
if setup_fail2ban "$etc" >"$FIXTURE/restart.log" 2>&1; then echo 'FAIL: start error ignored'; exit 1; fi
grep -Fq 'Не удалось запустить Fail2ban' "$FIXTURE/restart.log"
[[ ! -e $jail && ! -e $server && ! -e $FIXTURE/enabled ]]
grep -Fxq 'disable --now fail2ban.service' "$FIXTURE/systemctl.log"
rm -- "$FIXTURE/restart-fails"

printf '# admin policy\n' >"$jail"
if setup_fail2ban "$etc" >"$FIXTURE/custom.log" 2>&1; then echo 'FAIL: custom policy overwritten during retry'; exit 1; fi
grep -Fxq '# admin policy' "$jail"
rm -- "$jail"
ln -- "$etc/.autoxray-setup/jail" "$jail"
setup_fail2ban "$etc" >"$FIXTURE/retry.log"
grep -Fxq 'port = 2222,4444' "$jail"
[[ -f $server && -e $FIXTURE/enabled && ! -e $etc/.autoxray-setup ]]
printf 'OK: recovery after package install, service failures and interrupted file publication; admin policy preserved\n'

touch "$FIXTURE/active"
printf '198.51.100.%s\n' {1..12} >"$FIXTURE/bans"
printf '%s\n' '2001:db8::1' >>"$FIXTURE/bans"
TG_MSG='' TG_KB=''
tg_send() { TG_MSG=$2; TG_KB=${3:-}; }
tg_edit() { tg_send "$1" "$3" "${4:-}"; }
tg_answer() { :; }

message() {
  bot_handle_update "$(jq -nc --argjson uid "$1" --argjson chat "$2" --arg type "$3" --arg text "$4" \
    '{message:{from:{id:$uid},chat:{id:$chat,type:$type},text:$text}}')"
}
callback() {
  bot_handle_update "$(jq -nc --argjson uid "$1" --argjson chat "$2" --arg type "$3" --arg data "$4" \
    '{callback_query:{id:"cb",from:{id:$uid},data:$data,message:{message_id:1,chat:{id:$chat,type:$type}}}}')"
}
confirm_data() { jq -er '.inline_keyboard[0][0].callback_data' <<<"$TG_KB"; }
cancel_data() { jq -er '.inline_keyboard[0][1].callback_data' <<<"$TG_KB"; }

: >"$FIXTURE/client.log"
message 10003 10003 private /fail2ban
message 10001 -123 group '/unban 198.51.100.1'
[[ ! -s $FIXTURE/client.log ]]
message 10001 10001 private /fail2ban
assert_contains "$TG_MSG" 'Банов сейчас / всего: 13 / 29'
assert_contains "$TG_MSG" '<code>198.51.100.10</code>'
[[ $TG_MSG != *'<code>198.51.100.11</code>'* ]]
jq -e '[.inline_keyboard[][] | .callback_data] | index("f2b:p:1")' <<<"$TG_KB" >/dev/null
callback 10001 10001 private 'f2b:p:99999'
assert_contains "$TG_MSG" '<code>2001:db8::1</code>'
jq -e '[.inline_keyboard[][] | .callback_data] | index("f2b:ask:2001:db8::1")' <<<"$TG_KB" >/dev/null
printf 'OK: private admin reports and pagination with IPv4 and IPv6\n'

for value in '198.51.100.1;id' '--all' '198.51.100.1/24' '2001:db8::1%eth0' '999.1.2.3'; do
  message 10001 10001 private "/unban $value"
  assert_contains "$TG_MSG" 'Укажите один IPv4 или IPv6'
done
callback 10001 10001 private 'f2b:do:198.51.100.1'
assert_contains "$TG_MSG" 'Подтверждение недействительно'
callback 10001 10001 private 'f2b:ask:2001:0DB8:0000:0000:0000:0000:0000:0001'
assert_contains "$TG_MSG" 'Разблокировать <code>2001:db8::1</code>'
token=$(confirm_data)
callback 10002 10002 private "$token"
callback 10003 10003 private "$token"
callback 10001 -123 group "$token"
[[ ! -e $FIXTURE/unbans ]]
callback 10001 10001 private "$token" 2>"$FIXTURE/audit.log"
assert_contains "$TG_MSG" 'разблокирован в jail sshd'
[[ $(cat "$FIXTURE/unbans") == 2001:db8::1 ]]
grep -Fq 'jail=sshd action=unban admin=10001 ip=2001:db8::1 result=unbanned' "$FIXTURE/audit.log"
printf '%s\n' '2001:db8::1' >>"$FIXTURE/bans"
callback 10001 10001 private "$token"
[[ $(wc -l <"$FIXTURE/unbans") -eq 1 ]]
printf 'OK: validation, per-admin confirmation, audit and replay rejected after re-ban\n'

message 10001 10001 private '/unban 198.51.100.1'
token=$(confirm_data); cancel=$(cancel_data)
callback 10001 10001 private "$cancel"
callback 10001 10001 private "$token"
message 10001 10001 private '/unban 198.51.100.1'
token=$(confirm_data)
sed -i 's/ [0-9]*$/ 0/' "$F2B_RUN_DIR/fail2ban-confirm/10001"
callback 10001 10001 private "$token"
[[ $(wc -l <"$FIXTURE/unbans") -eq 1 ]]
printf 'OK: canceled and expired confirmations do not unban\n'

touch "$FIXTURE/bad-reply"
message 10001 10001 private '/unban 198.51.100.2'
assert_contains "$TG_MSG" 'недоступен'
rm -- "$FIXTURE/bad-reply"
message 10001 10001 private '/unban 198.51.100.2'
touch "$FIXTURE/unban-error"
callback 10001 10001 private "$(confirm_data)" 2>>"$FIXTURE/audit.log"
assert_contains "$TG_MSG" 'вернул ошибку'
rm -- "$FIXTURE/unban-error"
message 10001 10001 private '/unban 198.51.100.2'
touch "$FIXTURE/unavailable-after-unban"
callback 10001 10001 private "$(confirm_data)" 2>>"$FIXTURE/audit.log"
assert_contains "$TG_MSG" 'не удалось проверить'
grep -Fq 'result=unverified' "$FIXTURE/audit.log"
[[ ! -e $FIXTURE/unexpected-curl ]]
printf 'OK: backend errors and unknown state reported without false success\n'
