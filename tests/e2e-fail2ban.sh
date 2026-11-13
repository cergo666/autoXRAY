#!/usr/bin/env bash
# Ubuntu 24.04: отдельная ВМ с systemd и openssh-server, чистая от Fail2ban.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ $EUID != 0 || ${AX_FAIL2BAN_TEST_VM:-0} != 1 || $(ps -p 1 -o comm=) != systemd ]]; then
  echo 'Запускайте этот тест от root с AX_FAIL2BAN_TEST_VM=1 только на отдельной тестовой ВМ.' >&2
  exit 1
fi
if command -v fail2ban-client >/dev/null || [[ -e /etc/fail2ban || -L /etc/fail2ban ]]; then
  echo 'Для проверки первой установки нужна ВМ без Fail2ban и его конфигурации.' >&2
  exit 1
fi

ns=ax-f2b-test
account=ax-f2b-test
socket_dir=/run/systemd/system/ssh.socket.d
socket_conf="$socket_dir/99-autoxray-f2b-test.conf"
sshd_conf=/etc/ssh/sshd_config.d/00-autoxray-f2b-test.conf
jail=/etc/fail2ban/jail.d/90-autoxray-sshd.local
local_conf=/etc/fail2ban/jail.d/99-autoxray-test-local.local
host4=192.0.2.1 src4=192.0.2.2 control4=192.0.2.3
host6=2001:db8:54::1 src6=2001:db8:54::2 control6=2001:db8:54::3
old_port=22441 socket_port=22442 service_port=22443
if id "$account" >/dev/null 2>&1 || [[ -e /run/netns/$ns || -e $socket_conf || -e $sshd_conf || -e /etc/sudoers.d/$account ]] ||
   ip link show ax-f2b-host >/dev/null 2>&1; then
  echo 'Тестовые имена уже заняты. Используйте чистую тестовую ВМ.' >&2
  exit 1
fi
tmp=$(mktemp -d /run/autoxray-f2b-test.XXXXXX)
unset AX_DRY AX_FAIL2BAN
socket_active=0 service_active=0 socket_disabled=0 session_pid=
socket_enable_state=$(systemctl is-enabled ssh.socket || true)
if systemctl is-active --quiet ssh.socket; then socket_active=1; fi
if systemctl is-active --quiet ssh.service; then service_active=1; fi

cleanup() {
  local rc=$?
  if (( rc )); then
    if [[ -f $tmp/override.log ]]; then cat "$tmp/override.log" >&2; fi
    journalctl -u ssh.service -u fail2ban.service -n 35 --no-pager >&2 || true
    if command -v nft >/dev/null; then nft -nn list table inet f2b-table >&2 || true; fi
  fi
  if [[ -n $session_pid ]]; then kill "$session_pid" 2>/dev/null || true; fi
  systemctl stop fail2ban.service ssh.service ssh.socket 2>/dev/null || true
  rm -f -- "$socket_conf" "$sshd_conf" "$local_conf" "/etc/sudoers.d/$account"
  if (( socket_disabled )); then
    case $socket_enable_state in
      enabled) systemctl enable ssh.socket ;;
      enabled-runtime) systemctl enable --runtime ssh.socket ;;
    esac
  fi
  systemctl daemon-reload
  if (( socket_active )); then systemctl start ssh.socket || true; fi
  if (( service_active )); then systemctl start ssh.service || true; fi
  ip netns del "$ns" 2>/dev/null || true
  ip link del ax-f2b-host 2>/dev/null || true
  userdel -r "$account" 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'printf "Проверка Fail2ban остановилась на строке %s\n" "$LINENO" >&2' ERR

chmod 755 "$tmp"
install -m 755 autoxray "$tmp/autoxray"
useradd --create-home --user-group --shell /bin/bash "$account"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
install -d -m 700 -o "$account" -g "$account" "/home/$account/.ssh"
install -m 600 -o "$account" -g "$account" "$tmp/key.pub" "/home/$account/.ssh/authorized_keys"
printf '%s ALL=(root) NOPASSWD: /usr/bin/env -u AX_FAIL2BAN /usr/bin/bash %s setup-fail2ban --install\n' \
  "$account" "$tmp/autoxray" >"/etc/sudoers.d/$account"
chmod 440 "/etc/sudoers.d/$account"

ip netns add "$ns"
ip link add ax-f2b-host type veth peer name ax-f2b-peer
ip link set ax-f2b-peer netns "$ns"
ip address add "$host4/24" dev ax-f2b-host
ip -6 address add "$host6/64" dev ax-f2b-host nodad
ip link set ax-f2b-host up
ip -n "$ns" link set lo up
ip -n "$ns" link set ax-f2b-peer up
ip -n "$ns" address add "$src4/24" dev ax-f2b-peer
ip -n "$ns" address add "$control4/24" dev ax-f2b-peer
ip -n "$ns" -6 address add "$src6/64" dev ax-f2b-peer nodad
ip -n "$ns" -6 address add "$control6/64" dev ax-f2b-peer nodad

listen_socket() {
  install -d "$socket_dir"
  printf '[Socket]\nListenStream=\nListenStream=%s:%s\nListenStream=[%s]:%s\n' \
    "$host4" "$1" "$host6" "$1" >"$socket_conf"
  systemctl daemon-reload
  systemctl stop ssh.service ssh.socket
  systemctl start ssh.socket
}

ssh_from() {
  local source=$1 target=$2 port=$3 user=$4
  shift 4
  ip netns exec "$ns" ssh -F /dev/null -b "$source" -p "$port" -i "$tmp/key" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=20 "$user@$target" "$@"
}

wait_for() {
  local _
  for _ in {1..45}; do
    if "$@"; then return 0; fi
    sleep 0.25
  done
  return 1
}

expect_blocked() {
  if ssh_from "$1" "$2" "$3" "$account" true </dev/null 2>/dev/null; then
    printf 'Неожиданно открыт SSH с %s на порт %s\n' "$1" "$3" >&2
    return 1
  fi
}

banned() { [[ $(fail2ban-client get sshd banned "$1") == 1 ]]; }

nft_ready() {
  nft -nn list table inet f2b-table >"$tmp/nft" 2>/dev/null &&
    grep -Fq "tcp dport $1 ip saddr @" "$tmp/nft" && grep -Fq "tcp dport $1 ip6 saddr @" "$tmp/nft" &&
    grep -Fq "$src4" "$tmp/nft" && grep -Fq "$src6" "$tmp/nft"
}

check_port() {
  local port=$1 previous=${2:-}
  [[ $(fail2ban-client get sshd action nftables port) == "$port" ]]
  wait_for banned "$src4"
  wait_for banned "$src6"
  wait_for nft_ready "$port"
  if [[ -n $previous ]] && grep -Fq "tcp dport $previous " "$tmp/nft"; then
    echo "В nftables осталось правило для старого порта $previous" >&2
    return 1
  fi
  expect_blocked "$src4" "$host4" "$port"
  expect_blocked "$src6" "$host6" "$port"
  ssh_from "$control4" "$host4" "$port" "$account" true </dev/null
  ssh_from "$control6" "$host6" "$port" "$account" true </dev/null
}

listen_socket "$old_port"
since=$(date +%s)
for _ in {1..4}; do
  if ssh_from "$src4" "$host4" "$old_port" ax-f2b-invalid true </dev/null 2>/dev/null ||
     ssh_from "$src6" "$host6" "$old_port" ax-f2b-invalid true </dev/null 2>/dev/null; then
    echo 'Вход несуществующего пользователя неожиданно удался' >&2
    exit 1
  fi
done
journalctl -u ssh.service --since "@$since" --no-pager -o cat >"$tmp/ssh.log"
[[ $(grep -Fc "Invalid user ax-f2b-invalid from $src4" "$tmp/ssh.log") -ge 3 ]]
[[ $(grep -Fc "Invalid user ax-f2b-invalid from $src6" "$tmp/ssh.log") -ge 3 ]]

ssh_from "$src4" "$host4" "$old_port" "$account" \
  sudo -n /usr/bin/env -u AX_FAIL2BAN /usr/bin/bash "$tmp/autoxray" setup-fail2ban --install </dev/null
if command -v fail2ban-client >/dev/null || [[ -e /etc/fail2ban ]]; then
  echo 'Установщик включил Fail2ban без явного согласия' >&2
  exit 1
fi
ssh_from "$src4" "$host4" "$old_port" "$account" true </dev/null
ssh_from "$src6" "$host6" "$old_port" "$account" true </dev/null
echo 'OK: после недавних ошибок входа установщик по умолчанию оставляет повторный вход доступным'

mkfifo "$tmp/session.in"
: >"$tmp/session.out"
exec 3<>"$tmp/session.in"
ssh_from "$src4" "$host4" "$old_port" "$account" cat <"$tmp/session.in" >"$tmp/session.out" 3>&- &
session_pid=$!
printf '%s\n' before >&3
wait_for grep -Fxq before "$tmp/session.out"
AX_FAIL2BAN=y bash "$tmp/autoxray" setup-fail2ban --install </dev/null
check_port "$old_port"
printf '%s\n' after >&3
wait_for grep -Fxq after "$tmp/session.out"
exec 3>&-
echo 'OK: явное включение подхватывает реальные ошибки IPv4 и IPv6 и сохраняет открытый сеанс'

ban_times=$(fail2ban-client get sshd banip --with-time | sort)
daemon_pid=$(systemctl show --property=MainPID --value fail2ban.service)
listen_socket "$socket_port"
printf '[sshd]\nport = %s\n' "$old_port" >"$local_conf"
override_hash=$(sha256sum <"$local_conf")
if bash "$tmp/autoxray" setup-fail2ban >"$tmp/override.log" 2>&1; then
  echo 'Локальное переопределение портов принято как успешное обновление' >&2
  exit 1
fi
grep -Fq 'локальные переопределения' "$tmp/override.log"
grep -Fxq "port = $old_port" "$jail"
[[ $(sha256sum <"$local_conf") == "$override_hash" ]]
[[ $(fail2ban-client get sshd action nftables port) == "$old_port" ]]
printf '[sshd]\nmaxretry = 5\n' >"$local_conf"
local_hash=$(sha256sum <"$local_conf")
bash "$tmp/autoxray" setup-fail2ban
check_port "$socket_port" "$old_port"
[[ $(fail2ban-client get sshd maxretry) == 5 ]]
[[ $(sha256sum <"$local_conf") == "$local_hash" ]]
[[ $(fail2ban-client get sshd banip --with-time | sort) == "$ban_times" ]]
[[ $(systemctl show --property=MainPID --value fail2ban.service) == "$daemon_pid" ]]
echo 'OK: после смены ListenStream баны действуют на новом порту и сохраняют сроки'

systemctl stop ssh.service ssh.socket
# На Ubuntu включённый ssh.socket создаёт Requires для ssh.service.
socket_disabled=1
case $socket_enable_state in
  enabled) systemctl disable ssh.socket ;;
  enabled-runtime) systemctl disable --runtime ssh.socket ;;
esac
rm -- "$socket_conf"
printf 'Port %s\nListenAddress %s:%s\nListenAddress [%s]:%s\n' \
  "$service_port" "$host4" "$service_port" "$host6" "$service_port" >"$sshd_conf"
systemctl daemon-reload
systemctl start ssh.service
if systemctl is-active --quiet ssh.socket; then
  echo 'Для проверки Port требуется ssh.service без сокетной активации' >&2
  exit 1
fi
bash "$tmp/autoxray" setup-fail2ban
check_port "$service_port" "$socket_port"
[[ $(fail2ban-client get sshd banip --with-time | sort) == "$ban_times" ]]
[[ $(sha256sum <"$local_conf") == "$local_hash" ]]
echo 'OK: после смены Port без сокетной активации баны перенесены на новый порт'

(
  export AX_DRY=1 AX_ETC="$tmp/bot"
  mkdir -p "$AX_ETC"
  printf '%s\n' '{"bot":{"enabled":true,"admins":[10001]},"users":[]}' >"$AX_ETC/state.json"
  printf '%s\n' test-token >"$AX_ETC/bot.token"
  # shellcheck source=autoxray
  AX_UNIT_TEST=1 source "$tmp/autoxray"
  # shellcheck disable=SC2034
  F2B_RUN_DIR="$tmp/bot-runtime"
  TG_MESSAGE='' TG_KEYBOARD=''
  tg_send() { TG_MESSAGE=$2; TG_KEYBOARD=${3:-}; }
  tg_answer() { :; }
  for address in "$src4" "$src6"; do
    bot_handle_update "$(jq -cn --arg text "/unban $address" '{message:{chat:{id:10001,type:"private"},from:{id:10001},text:$text}}')"
    callback=$(jq -er '.inline_keyboard[0][0].callback_data' <<<"$TG_KEYBOARD")
    [[ $callback =~ ^f2b:do:[0-9a-f]{32}$ ]]
    banned "$address"
    bot_handle_update "$(jq -cn --arg data "$callback" '{callback_query:{id:"lab",data:$data,from:{id:10001},message:{message_id:1,chat:{id:10001,type:"private"}}}}')"
    [[ $TG_MESSAGE == *'разблокирован в jail sshd'* || $TG_MESSAGE == *'больше не заблокирован в jail sshd'* ]]
    [[ $(fail2ban-client get sshd banned "$address") == 0 ]]
  done
)
wait_for ssh_from "$src4" "$host4" "$service_port" "$account" true </dev/null
wait_for ssh_from "$src6" "$host6" "$service_port" "$account" true </dev/null
echo 'OK: подтверждённый /unban восстановил реальный доступ IPv4 и IPv6'
