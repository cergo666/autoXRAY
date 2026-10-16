#!/bin/bash
# e2e режима «bridge» (две машины): EU-сервер (direct) и RU-мост, клиент -> RU -> EU -> цель.
# Запускается orchestrator'ом e2e-bridge-host.sh: `e2e-bridge.sh eu` и `e2e-bridge.sh ru` в разных контейнерах.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

role=${1:?role eu|ru}
CA=/tmp/ca            # общий каталог с CA (монтируется в оба контейнера)
SHARED=$CA/shared

if [ "$role" = eu ]; then
    export DOMAIN=eu.test
    step "EU: сервер в режиме direct, два пользователя-«узла» для моста"
    echo "127.0.0.1 $DOMAIN" >> /etc/hosts
    setup_tls "$DOMAIN" "$CA"; install_cli; start_target
    mkdir -p "/var/www/$DOMAIN" "$SHARED"
    bash /opt/autoxray/templates/gen_page.sh "/var/www/$DOMAIN" >/dev/null
    autoxray init --domain "$DOMAIN" --fp firefox --xhttp-path eu9x2q --web "/var/www/$DOMAIN" --user bridge1 >/dev/null || fail "init"
    autoxray user add bridge2 >/dev/null || fail "user add"
    check "EU render" autoxray render
    for u in bridge1 bridge2; do autoxray user link "$u" --plain | head -n1 | cut -d'|' -f2 > "$SHARED/$u.link"; done
    check "EU: ссылки узлов выданы" test -s "$SHARED/bridge2.link"
    touch "$SHARED/eu.ready"
    finish
    exit
fi

# ---------------------------------------------------------------- RU
export DOMAIN=ru.test
EU_IP=${EU_IP:?EU_IP}
step "RU: мост из двух EU-узлов (ссылки с IP вместо имени — DNS в тесте не нужен)"
echo "127.0.0.1 $DOMAIN" >> /etc/hosts
setup_tls "$DOMAIN" "$CA"; install_cli
mkdir -p "/var/www/$DOMAIN"
bash /opt/autoxray/templates/gen_page.sh "/var/www/$DOMAIN" >/dev/null
L1=$(sed "s/@eu.test:443/@$EU_IP:443/" "$SHARED/bridge1.link")
L2=$(sed "s/@eu.test:443/@$EU_IP:443/" "$SHARED/bridge2.link")
autoxray init --domain "$DOMAIN" --fp chrome --xhttp-path ru4n8k --web "/var/www/$DOMAIN" --user anna --mode bridge \
    --node "$L1#DE-1" --node "$L2#DE-2" >/dev/null || fail "init bridge"
check "RU render (xray -test с balancer и vlessRoute)" autoxray render
check "xray -test принимает конфиг моста" xray run -test -c /usr/local/etc/xray/config.json
check "nginx -t" nginx -t
autoxray node list
[ "$(jq '.inbounds[0].settings.clients[0].id | .[14:18]' /usr/local/etc/xray/config.json)" = '"0000"' ] && pass "UUID пользователя моста с route 0000" || fail "route-группа UUID"

step "Подписка моста через 443"
TOKEN=$(jq -r '.users[0].token' /etc/autoxray/state.json)
curl -sS --max-time 8 "https://$DOMAIN/$TOKEN.json" -o /tmp/sub.json
n=$(jq length /tmp/sub.json)
[ "$n" = 7 ] && pass "7 профилей (авто + 2 узла × 3)" || fail "профилей: $n"
jq -r '.[].remarks' /tmp/sub.json

names=("авто-балансировщик" "RU>EU xhttp DE-1" "RU>EU raw DE-1" "EU direct DE-1" "RU>EU xhttp DE-2" "RU>EU raw DE-2" "EU direct DE-2")
for i in 0 1 2 3 4 5 6; do
    step "Цепочка клиент -> RU -> EU -> цель: ${names[$i]}"
    addr=127.0.0.1; [[ ${names[$i]} == "EU direct"* ]] && addr=$EU_IP
    client_cfg "$TOKEN" "$i" "$addr" > "/tmp/cl-$i.json"
    if client_start "/tmp/cl-$i.json" && out=$(via_proxy ok.txt 2>&1) && [ "$out" = TARGET-OK ]; then
        pass "${names[$i]}: запрос дошёл до цели, которая доступна только на EU"
    else
        fail "${names[$i]}: '${out:-}'"; tail -n 6 /tmp/client.out; tail -n 6 /var/log/xray/server.out
    fi
done
client_stop

step "Учёт трафика на RU"
autoxray collect
tot=$(jq '[.[] | .up + .down] | add // 0' /etc/autoxray/traffic.json)
[ "$tot" -gt 0 ] && pass "RU учёл трафик anna: $tot байт" || fail "RU не учёл трафик"
touch "$SHARED/ru.done"
finish
