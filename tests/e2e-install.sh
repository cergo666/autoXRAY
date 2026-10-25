#!/bin/bash
# e2e самого install.sh (с заглушками apt/acme/Xray-install): fresh | migrate
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

scenario=${1:-fresh}
export DOMAIN=vpn.test
WEB=/var/www/$DOMAIN
echo "127.0.0.1 $DOMAIN" >> /etc/hosts
export PATH=/opt/autoxray/tests/stubs:$PATH

if [ "$scenario" = verify ]; then
    step "install.sh: контрольные суммы релиза"
    export PATH=/opt/autoxray/tests/stubs:$PATH
    rm -rf /tmp/rel/v9.9.9; mkdir -p /tmp/rel/v9.9.9; cp -r /opt/autoxray/autoxray /opt/autoxray/templates /opt/autoxray/components /tmp/rel/v9.9.9/
    (cd /tmp/rel/v9.9.9 && files=$(sed -n '/^RELEASE_FILES=(/,/)/p' autoxray | tr -d '()' | sed 's/^RELEASE_FILES=//' | tr ' ' '\n' | grep -E '^[A-Za-z0-9_./-]+$') && sha256sum $files > FILES.sha256)
    echo '<!-- подмена -->' >> /tmp/rel/v9.9.9/templates/sub.html
    AX_TG=n AX_FP=2 AX_USER=anna AX_WARP=n AUTOXRAY_REF=v9.9.9 AUTOXRAY_RAW=file:///tmp/rel AX_SUMS_BASE=file:///tmp/rel \
        bash /opt/autoxray/install.sh vpn.test </dev/null >/tmp/install-tamper.log 2>&1 && fail "install.sh принял подменённый файл" \
        || { grep -q 'не совпали' /tmp/install-tamper.log && pass "install.sh с подменённым файлом остановился" || { fail "install.sh: другая причина"; tail -n 8 /tmp/install-tamper.log; }; }
    [ ! -e /usr/local/bin/autoxray ] && pass "при несовпадении сумм ничего не установлено" || fail "autoxray установлен несмотря на подмену"
    finish; exit
fi

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
check "cron: учёт трафика, лимит IP, гео-данные" bash -c 'grep -q collect /etc/cron.d/autoxray && grep -q ipwatch /etc/cron.d/autoxray && grep -q geo-update /etc/cron.d/autoxray'
[ "$(stat -c %a /var/lib/xray/cert/privkey.pem)" = 640 ] && pass "ключ TLS: права 640" || fail "права ключа: $(stat -c %a /var/lib/xray/cert/privkey.pem)"
TOKEN=$(jq -r '.users[0].token' /etc/autoxray/state.json)
check "подписка отдаётся (три протокола и «Авто»)" bash -c "curl -fsS --max-time 8 https://$DOMAIN/$TOKEN.json | jq -e 'length == 4'"
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
jq '.[1] | .outbounds[0].settings.vnext[0].address = "127.0.0.1" | .outbounds[0].streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/tmp/ca/ca.pem"}]' "$WEB/sub-copy.json" > /tmp/cl.json
client_start /tmp/cl.json && via_proxy ok.txt >/dev/null && pass "трафик идёт" || fail "трафик не идёт"
client_stop

step "Повторный запуск install.sh сохраняет пользователей"
uuid_before=$(jq -r '.users[0].uuid' /etc/autoxray/state.json)
run_install 1 y && pass "повторный install.sh успешен" || { fail "повторный install.sh упал"; tail -n 15 /tmp/install.log; }
[ "$uuid_before" = "$(jq -r '.users[0].uuid' /etc/autoxray/state.json)" ] && pass "UUID не изменился при повторном запуске" || fail "UUID изменился"

finish
