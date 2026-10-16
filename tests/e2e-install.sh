#!/bin/bash
# e2e самого install.sh (с заглушками apt/acme/Xray-install): fresh | migrate
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

scenario=${1:-fresh}
export DOMAIN=vpn.test
WEB=/var/www/$DOMAIN
echo "127.0.0.1 $DOMAIN" >> /etc/hosts
export PATH=/opt/autoxray/tests/stubs:$PATH

step "Окружение: сертификат (его «выпустит» заглушка acme.sh), цель"
mkdir -p /var/lib/xray/cert /root/.acme.sh
setup_tls "$DOMAIN"
cp /opt/autoxray/tests/stubs/acme.sh /root/.acme.sh/acme.sh
start_target

run_install() {
    AX_TG=n AX_FP=${1:-2} AX_USER=anna AX_WARP=n AX_MIGRATE=${2:-y} AUTOXRAY_SRC=/opt/autoxray \
        bash /opt/autoxray/install.sh "$DOMAIN" </dev/null >/tmp/install.log 2>&1
}

if [ "$scenario" = migrate ]; then
    step "Подготовка «старой» установки autoXRAY 2"
    mkdir -p "$WEB" /usr/local/etc/xray
    export xray_uuid_vrv=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee xray_shortIds_vrv=0123456789abcdef path_xhttp=xp1234 socksUser=su1 socksPasw=sp1 path_subpage=OldSubToken1234567890
    envsubst < /opt/autoxray/tests/fixtures/v2-config.json.tpl > /usr/local/etc/xray/config.json
    printf 'server {\n    location = /OldSubToken1234567890.json {\n        try_files $uri =404;\n    }\n}\n' > /etc/nginx/conf.d/default.conf
    echo '[{"outbounds":[{"streamSettings":{"tlsSettings":{"fingerprint":"edge"}}}]}]' > "$WEB/OldSubToken1234567890.json"
fi

step "install.sh $scenario"
run_install 2 y && pass "install.sh завершился успешно" || { fail "install.sh упал"; tail -n 25 /tmp/install.log; finish; exit 1; }
tail -n 12 /tmp/install.log | sed 's/\x1b\[[0-9;]*m//g'
grep -qF '\033' /tmp/install.log && fail "в выводе установщика остались «сырые» escape-последовательности" || pass "вывод установщика без «сырых» escape-кодов"

step "Результат установки"
check "state.json создан" test -s /etc/autoxray/state.json
check "autoxray в PATH" autoxray version
check "xray -test" xray run -test -c /usr/local/etc/xray/config.json
check "nginx -t" nginx -t
check "xray и nginx запущены" bash -c 'pgrep -x xray && pgrep -x nginx'
check "cron для учёта трафика" test -f /etc/cron.d/autoxray
[ "$(stat -c %a /var/lib/xray/cert/privkey.pem)" = 640 ] && pass "ключ TLS: права 640" || fail "права ключа: $(stat -c %a /var/lib/xray/cert/privkey.pem)"
TOKEN=$(jq -r '.users[0].token' /etc/autoxray/state.json)
check "подписка отдаётся" bash -c "curl -fsS --max-time 8 https://$DOMAIN/$TOKEN.json | jq -e 'length == 3'"
check "страница пользователя" curl -fsS --max-time 8 "https://$DOMAIN/$TOKEN.html" -o /dev/null

if [ "$scenario" = migrate ]; then
    [ "$TOKEN" = OldSubToken1234567890 ] && pass "ссылка подписки осталась прежней" || fail "токен изменился: $TOKEN"
    [ "$(jq -r '.users[0].uuid' /etc/autoxray/state.json)" = aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee ] && pass "UUID сохранён" || fail "UUID изменился"
    [ "$(jq -r .fingerprint /etc/autoxray/state.json)" = edge ] && pass "fingerprint взят из старой подписки" || fail "fingerprint"
    [ "$(jq -r '.inbounds[] | select(.tag=="Hysteria2") | .settings.clients[0].auth' /usr/local/etc/xray/config.json)" = 0123456789abcdef ] && pass "пароль Hysteria2 сохранён" || fail "пароль Hysteria2"
    check "бэкап старого config.json" test -s /etc/autoxray/config.v2.json.bak
fi

step "Трафик через установленный сервер (RAW Vision)"
curl -fsS --max-time 8 "https://$DOMAIN/$TOKEN.json" -o "$WEB/sub-copy.json"
jq '.[1] | .outbounds[0].settings.vnext[0].address = "127.0.0.1"' "$WEB/sub-copy.json" > /tmp/cl.json
client_start /tmp/cl.json && via_proxy ok.txt >/dev/null && pass "трафик идёт" || fail "трафик не идёт"
client_stop

step "Повторный запуск install.sh сохраняет пользователей"
uuid_before=$(jq -r '.users[0].uuid' /etc/autoxray/state.json)
run_install 1 y && pass "повторный install.sh успешен" || { fail "повторный install.sh упал"; tail -n 15 /tmp/install.log; }
[ "$uuid_before" = "$(jq -r '.users[0].uuid' /etc/autoxray/state.json)" ] && pass "UUID не изменился при повторном запуске" || fail "UUID изменился"

finish
