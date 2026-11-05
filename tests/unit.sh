#!/bin/bash
# Юнит-тесты чистых функций autoxray (без установки Xray, nginx, сети).
# Запуск: bash tests/unit.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok_test() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail_test() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# Зависимости
command -v jq >/dev/null 2>&1 || { echo "jq не установлен — тесты не могут работать"; exit 1; }

# Подключаем autoxray, но не запускаем main (защита AX_UNIT_TEST)
AX_UNIT_TEST=1 source "$SCRIPT_DIR/autoxray"

# -------------------------------------------------------- route_norm
echo "== route_norm: домены, IPv4, IPv6 =="

check_route() { local desc="$1" input="$2" expected="$3"; local r; r=$(route_norm "$input" 2>/dev/null); local rc=$?; if [[ $rc -eq 0 && "$r" == "$expected" ]]; then ok_test "$desc → $r"; else fail_test "$desc (ожидалось '$expected', получено '$r', код $rc)"; fi; }
check_route_fail() { local desc="$1" input="$2"; local r; r=$(route_norm "$input" 2>/dev/null); local rc=$?; if [[ $rc -ne 0 ]]; then ok_test "$desc → ошибка"; else fail_test "$desc (должен быть ошибкой, получено '$r')"; fi; }

check_route "example.com" "example.com" "example.com"
check_route "HTTPS URL" "  HTTPs://Sub.DOMAIN.Path/Page  " "sub.domain.path"
check_route "IPv4" "1.2.3.4" "1.2.3.4"
check_route "IPv4 сеть /8" "10.0.0.0/8" "10.0.0.0/8"
check_route "IPv6" "2001:db8::1" "2001:db8::1"
check_route "IPv6 сеть /32" "2001:db8::/32" "2001:db8::/32"
check_route "punycode" "xn--p1ai" "xn--p1ai"
check_route_fail "недомен" "недомен"
check_route_fail "плохой IPv4" "1.2.3.999"

# -------------------------------------------------------- valid_trust
echo "== valid_trust: IP и сети =="

check_valid() { local desc="$1" input="$2"; if valid_trust "$input" 2>/dev/null; then ok_test "$desc валиден"; else fail_test "$desc должен быть валидным"; fi; }
check_valid_fail() { local desc="$1" input="$2"; if valid_trust "$input" 2>/dev/null; then fail_test "$desc не должен быть валидным"; else ok_test "$desc → ошибка"; fi; }

check_valid "IPv4" "1.2.3.4"
check_valid "IPv4 /8" "10.0.0.0/8"
check_valid "IPv4 /32" "255.255.255.255/32"
check_valid_fail "IPv4 /7" "1.2.3.4/7"
check_valid_fail "IPv4 /33" "1.2.3.4/33"
check_valid "IPv6" "2001:db8::1"
check_valid "IPv6 /32" "2001:db8::/32"
check_valid "IPv6 /128" "2001:db8::/128"
check_valid_fail "IPv6 /7" "2001:db8::/7"
check_valid_fail "IPv6 /129" "2001:db8::/129"
check_valid_fail "чепуха" "not.an.ip"

# -------------------------------------------------------- ip62hexa
echo "== ip62hexa: сокращение :: =="

check_hex() { local desc="$1" input="$2" expected="$3"; local h; h=$(ip62hexa "$input"); if [[ "$h" == "$expected" ]]; then ok_test "$desc → $h"; else fail_test "$desc (ожидалось '$expected', получено '$h')"; fi; }

check_hex "::1" "::1" "00000000000000000000000000000001"
check_hex "2001:db8::1" "2001:db8::1" "20010db8000000000000000000000001"
check_hex "fe80::1 prefix" "fe80::1" "fe800000000000000000000000000001"
h32=$(ip62hexa "2001:db8:85a3::8a2e:370:7334"); [[ ${#h32} -eq 32 ]] && ok_test "длина 32 hex → ${#h32}" || fail_test "длина ${#h32}"

# -------------------------------------------------------- ip_in
echo "== ip_in: IPv4 и IPv6 в списках =="

check_ipin() { local desc="$1" ip="$2" ip_list="$3"; if ip_in "$ip" "$ip_list"; then ok_test "$desc"; else fail_test "$desc"; fi; }
check_ipin_fail() { local desc="$1" ip="$2" ip_list="$3"; if ip_in "$ip" "$ip_list" 2>/dev/null; then fail_test "$desc не должен совпадать"; else ok_test "$desc → не в списке"; fi; }

check_ipin "IPv4 в сети /8" "10.0.0.5" "10.0.0.0/8 192.168.0.0/16"
check_ipin_fail "IPv4 не в сети" "192.168.1.1" "10.0.0.0/8"
check_ipin "IPv6 в сети /32" "2001:db8::42" "2001:db8::/32"
check_ipin_fail "IPv6 другая сеть" "2001:db9::1" "2001:db8::/32"
check_ipin "IPv6 точное совпадение" "::1" "::1 2001:db8::/32"
check_ipin "IPv6 в сети /48" "2001:db8:1234::1" "2001:db8:1234::/48"

# -------------------------------------------------------- ver_gt
echo "== ver_gt: сравнение версий =="

check_ver() { local desc="$1" a="$2" b="$3"; if ver_gt "$a" "$b"; then ok_test "$desc"; else fail_test "$desc"; fi; }
check_ver_fail() { local desc="$1" a="$2" b="$3"; if ver_gt "$a" "$b" 2>/dev/null; then fail_test "$desc не должен быть больше"; else ok_test "$desc → не больше"; fi; }

check_ver "26.10.31 > 26.10.30" "26.10.31" "26.10.30"
check_ver_fail "равные версии" "1.2.3" "1.2.3"
check_ver "v1.0.0 > 0.9.9" "v1.0.0" "0.9.9"
check_ver_fail "1.0 не больше 1.0.1" "1.0" "1.0.1"

# -------------------------------------------------------- days_left
echo "== days_left =="

now_ts=$(date +%s)
dl=$(days_left $((now_ts + 86400))); [[ "$dl" == "1" ]] && ok_test "завтра → $dl" || fail_test "завтра → $dl ($dl)"
dl=$(days_left "$now_ts"); [[ "$dl" == "0" ]] && ok_test "сейчас → $dl" || fail_test "сейчас → $dl ($dl)"

# -------------------------------------------------------- parse_vless
echo "== parse_vless: vless:// ссылки =="

j=$(parse_vless "vless://f47ac10b-58cc-4372-a567-0e02b2c3d479@example.com:443?security=tls&type=xhttp&path=/xh#Мой узел" 2>/dev/null) || { fail_test "parse_vless не вернул JSON"; j="{}"; }
name=$(jq -r '.name' <<<"$j"); [[ "$name" == "Мой узел" ]] && ok_test "имя узла → $name" || fail_test "имя узла → $name (получено: $name)"
uuid=$(jq -r '.uuid' <<<"$j"); [[ "$uuid" == "f47ac10b-58cc-4372-a567-0e02b2c3d479" ]] && ok_test "UUID → $uuid" || fail_test "UUID → $uuid (получено: $uuid)"
addr=$(jq -r '.addr' <<<"$j"); [[ "$addr" == "example.com" ]] && ok_test "адрес → $addr" || fail_test "адрес → $addr (получено: $addr)"
port=$(jq -r '.port' <<<"$j"); [[ "$port" == "443" ]] && ok_test "порт → $port" || fail_test "порт → $port (получено: $port)"
sec=$(jq -r '.security' <<<"$j"); [[ "$sec" == "tls" ]] && ok_test "security → $sec" || fail_test "security → $sec (получено: $sec)"
parse_vless "not-a-vless-url" 2>/dev/null && fail_test "не vless ссылка должна быть ошибкой" || ok_test "не vless → ошибка"

# -------------------------------------------------------- urldecode
echo "== urldecode =="

d=$(urldecode "hello%20world"); [[ "$d" == "hello world" ]] && ok_test "urldecode → $d" || fail_test "urldecode → $d"
d=$(urldecode "%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82"); [[ "$d" == "Привет" ]] && ok_test "urldecode UTF-8 → $d" || fail_test "urldecode UTF-8 → $d"

# -------------------------------------------------------- hop_range
echo "== hop_range (из state, если есть) =="
if [[ -f /etc/autoxray/state.json ]]; then
  r=$(hop_range); ok_test "hop_range → $r"
else
  echo "  ⏭ state.json нет, пропускаем hop_range"
fi

# -------------------------------------------------------- next_reset_ts
echo "== next_reset_ts =="

nr=$(next_reset_ts monthly); [[ $nr -gt $(date +%s) ]] && ok_test "monthly → $nr" || fail_test "monthly"
nr=$(next_reset_ts weekly); [[ $nr -gt $(date +%s) ]] && ok_test "weekly → $nr" || fail_test "weekly"
nr=$(next_reset_ts never); [[ "$nr" == "0" ]] && ok_test "never → $nr" || fail_test "never → $nr"

echo
echo "================================"
echo "  ✅ пройдено: $PASS"
echo "  ❌ провалено: $FAIL"
echo "================================"
[[ $FAIL -eq 0 ]]
