#!/bin/bash
# e2e режима «direct»: настоящие Xray и nginx в контейнере, клиент Xray ходит через сервер.
# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export DOMAIN=vpn.test
WEB=/var/www/$DOMAIN
echo "127.0.0.1 $DOMAIN" >> /etc/hosts

step "Подготовка: TLS, CLI, цель за пределами сервера"
setup_tls "$DOMAIN"
install_cli
start_target
check "цель отвечает напрямую" curl -fsS --max-time 5 http://93.184.216.34:8080/ok.txt

step "Установка: init + сайт-маскировка + render (Xray -test и nginx -t настоящие)"
mkdir -p "$WEB"
AX_AUTH=/auth/session
bash /opt/autoxray/templates/gen_page.sh "$WEB" "$AX_AUTH" >/dev/null
check "gen_page создал index.html" test -s "$WEB/index.html"
autoxray init --domain "$DOMAIN" --fp chrome --xhttp-path xh7k2m --auth-path "$AX_AUTH" --web "$WEB" --user alice --xray-version v26.9.9 \
    || fail "init"
autoxray user add bob --limit 0.000001 || fail "user add bob"
check "render без ошибок" autoxray render
check "xray -test принимает конфиг" xray run -test -c /usr/local/etc/xray/config.json
check "nginx -t принимает конфиг" nginx -t
check "xray запущен" pgrep -x xray
check "nginx запущен" pgrep -x nginx
ss -ltn | grep -q ':443 ' && pass "443/tcp слушается" || fail "443/tcp не слушается"
ss -lun | grep -q ':443 ' && pass "443/udp (Hysteria2) слушается" || fail "443/udp не слушается"

step "Сайт-маскировка и подписка через 443 (xray fallback -> nginx)"
TOKEN_A=$(jq -r '.users[] | select(.name=="alice").token' /etc/autoxray/state.json)
TOKEN_B=$(jq -r '.users[] | select(.name=="bob").token' /etc/autoxray/state.json)
check "главная страница сайта-маскировки" curl -fsS --max-time 8 "https://$DOMAIN/" -o /dev/null
code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST "https://$DOMAIN$AX_AUTH"); [ "$code" = 401 ] && pass "форма входа отвечает 401" || fail "форма входа: $code"
curl -sS --max-time 8 -D /tmp/h.txt -o /tmp/sub.json "https://$DOMAIN/$TOKEN_A.json"
check "подписка alice — валидный JSON с 3 профилями" jq -e 'length == 3' /tmp/sub.json
grep -qi '^subscription-userinfo: upload=0; download=0' /tmp/h.txt && pass "заголовок subscription-userinfo" || { fail "нет subscription-userinfo"; cat /tmp/h.txt; }
check "страница alice (html)" curl -fsS --max-time 8 "https://$DOMAIN/$TOKEN_A.html" -o /dev/null
code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/ZZZZZZZZZZZZZZZZZZZZZZZZ.json"); [ "$code" = 404 ] && pass "чужой токен -> 404" || fail "чужой токен: $code"

for spec in "0 XHTTP stream-up" "1 RAW Vision" "2 Hysteria2"; do
    idx=${spec%% *}; name=${spec#* }
    step "Трафик через сервер: $name (alice)"
    client_cfg "$TOKEN_A" "$idx" 127.0.0.1 > /tmp/client-$idx.json
    if client_start /tmp/client-$idx.json; then
        out=$(via_proxy ok.txt 2>&1)
        [ "$out" = "TARGET-OK" ] && pass "$name: запрос дошёл до цели" || { fail "$name: ответ '$out'"; tail -n 8 /tmp/client.out; tail -n 8 /var/log/xray/server.out; }
    else
        fail "$name: клиент не стартовал"
    fi
done
client_stop

step "Учёт трафика: collect читает статистику настоящего Xray"
autoxray collect
up=$(jq '.alice.up // 0' /etc/autoxray/traffic.json); down=$(jq '.alice.down // 0' /etc/autoxray/traffic.json)
[ "$((up + down))" -gt 0 ] && pass "alice: ↑$up ↓$down байт учтено" || { fail "трафик alice не учтён"; cat /etc/autoxray/traffic.json; }
autoxray stats

step "Лимит: bob с лимитом ~1 КБ"
client_cfg "$TOKEN_B" 1 127.0.0.1 > /tmp/client-b.json
client_start /tmp/client-b.json && via_proxy ok.txt >/dev/null && pass "bob: первый запрос проходит" || fail "bob: первый запрос"
curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:10808 http://93.184.216.34:8080/ok.txt -o /dev/null
head -c 20000 /dev/urandom > /srv/target/big.bin; via_proxy big.bin >/dev/null
autoxray collect
[ "$(ustatus bob)" = limit ] && pass "bob переведён в limit" || { fail "bob не в limit: $(ustatus bob)"; autoxray user list; }
[ "$(jq '[.inbounds[0].settings.clients[].email] | index("bob")' /usr/local/etc/xray/config.json)" = null ] && pass "bob удалён из конфига Xray" || fail "bob остался в конфиге"
client_stop; client_start /tmp/client-b.json
via_proxy ok.txt >/dev/null 2>&1 && fail "bob всё ещё проходит после лимита" || pass "bob после лимита не проходит"
client_stop
client_start /tmp/client-0.json; via_proxy ok.txt >/dev/null 2>&1 && pass "alice продолжает работать" || fail "alice сломалась после рестарта"
client_stop

step "Управление: reset, rotate, del"
autoxray user set bob --limit 0 --reset-traffic && [ "$(ustatus bob)" = active ] && pass "bob снова active" || fail "bob не восстановился"
old_uuid=$(jq -r '.users[] | select(.name=="alice").uuid' /etc/autoxray/state.json)
autoxray user rotate alice >/dev/null
new_uuid=$(jq -r '.users[] | select(.name=="alice").uuid' /etc/autoxray/state.json)
[ "$old_uuid" != "$new_uuid" ] && pass "rotate сменил UUID" || fail "rotate не сменил UUID"
code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/$TOKEN_A.json"); [ "$code" = 404 ] && pass "старая ссылка alice мертва" || fail "старая ссылка жива: $code"
autoxray user del bob >/dev/null && pass "bob удалён" || fail "del bob"
code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/$TOKEN_B.json"); [ "$code" = 404 ] && pass "ссылка bob мертва" || fail "ссылка bob жива: $code"

step "WARP: регистрация (заглушка Cloudflare API) + настоящий xray -test с wireguard-outbound"
cat > /tmp/fakecurl <<'FC'
#!/bin/bash
if [[ "$*" == *"-X POST"* ]]; then echo '{"result":{"id":"dev-1","token":"tok","config":{"client_id":"AbCd"}}}'
else echo '{"result":{"config":{"client_id":"AbCd","peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}],"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:8a36::2"}}}}}'; fi
FC
chmod +x /tmp/fakecurl
# без --force WARP обязан отказаться включаться, если профиль не отвечает (здесь профиль «ненастоящий»)
AX_CURL=/tmp/fakecurl AX_WARP_CANDIDATES="162.159.192.1:2408" autoxray warp ru on >/tmp/warp-on.out 2>&1 && fail "warp ru on включился без рабочего WARP" || pass "warp ru on отказывается включаться без рабочего WARP"
[ "$(jq -r '.warp.enabled' /etc/autoxray/state.json)" = false ] && pass "RU через WARP не включён после отказа" || fail "WARP включён несмотря на отказ"
check "warp debug --quick отрабатывает и сообщает о проблеме" bash -c 'AX_WARP_CANDIDATES="162.159.192.1:2408" autoxray warp debug --quick; [ $? -eq 1 ]'
autoxray warp ru on --force && pass "warp ru on --force" || fail "warp ru on --force"
check "xray -test с wireguard-outbound и RU-правилами" xray run -test -c /usr/local/etc/xray/config.json
jq -e '.outbounds[] | select(.tag=="warp" and .protocol=="wireguard")' /usr/local/etc/xray/config.json >/dev/null && pass "outbound warp в конфиге" || fail "нет outbound warp"
TOKEN_A=$(jq -r '.users[] | select(.name=="alice").token' /etc/autoxray/state.json)
jq -e '.[0].routing.rules | map(.ip // [] | index("geoip:ru")) | any(. != null) | not' "$WEB/$TOKEN_A.json" >/dev/null && pass "клиентский профиль: RU больше не direct" || fail "RU остался direct в клиенте"
client_cfg "$TOKEN_A" 1 127.0.0.1 > /tmp/client-w.json
client_start /tmp/client-w.json && via_proxy ok.txt >/dev/null && pass "трафик идёт при включённом WARP (не-RU напрямую)" || fail "трафик сломан при WARP"
client_stop
autoxray warp ru off >/dev/null && check "warp ru off + xray -test" xray run -test -c /usr/local/etc/xray/config.json
autoxray warp off >/dev/null && check "warp off + xray -test" xray run -test -c /usr/local/etc/xray/config.json

step "Версии: баннер обновления и список версий ядра (поддельный GitHub API)"
mkdir -p /tmp/api/repos/cergo666/autoXRAY/releases /tmp/api/repos/XTLS/Xray-core
echo '{"tag_name":"v99.0.0"}' > /tmp/api/repos/cergo666/autoXRAY/releases/latest
echo '[{"tag_name":"v99.1.0","prerelease":false,"draft":false},{"tag_name":"v100.0.0","prerelease":true,"draft":false},{"tag_name":"v26.9.9","prerelease":false,"draft":false}]' > /tmp/api/repos/XTLS/Xray-core/releases
rm -f /etc/autoxray/.latest
AX_API=file:///tmp/api autoxray status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'Доступна версия 99.0.0' && pass "баннер: доступна новая версия autoxray" || fail "баннера обновления нет"
AX_API=file:///tmp/api autoxray core list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > /tmp/core.out
grep -q 'v99.1.0' /tmp/core.out && ! grep -q 'v100.0.0' /tmp/core.out && pass "core list: новее текущей, без предрелизов" || { fail "core list"; cat /tmp/core.out; }
grep -q 'лучше не обновлять без необходимости' /tmp/core.out && pass "предупреждение об обновлении ядра" || fail "нет предупреждения"
printf 'no\n' | autoxray core update v26.9.9 >/tmp/core-up.out 2>&1; grep -q 'Отменено' /tmp/core-up.out && pass "core update без подтверждения отменяется" || { fail "core update не спросил"; cat /tmp/core-up.out; }
step "Выбор пользователя без терминала (нумерованный список)"
out=$(bash -c 'source <(sed -n "/^choose()/,/^}/p; /^CHOICE=/p" /opt/autoxray/autoxray); choose "T" "a" "b" "c" <<<2; echo "rc=$? CHOICE=$CHOICE"')
echo "$out" | grep -q 'rc=0 CHOICE=1' && pass "choose: пункт 2 -> индекс 1" || fail "choose: $out"

step "Диагностика, гео-данные, файрвол (dry-run), интерфейс"
autoxray doctor > /tmp/doctor.out 2>&1 && pass "doctor: критичных проблем нет" || { fail "doctor нашёл проблемы"; sed "s/\x1b\[[0-9;]*m//g" /tmp/doctor.out; }
check "firewall --dry-run" autoxray firewall --dry-run
check "geo-update (настоящий install-geodata)" autoxray geo-update
check "status/stats/user list печатаются" bash -c 'autoxray status && autoxray stats && autoxray user list'
[ "$(autoxray user list | sed "s/\x1b\[[0-9;]*m//g" | grep -c "активен")" -ge 1 ] && pass "список пользователей с русскими статусами" || fail "список пользователей"
check "help" bash -c 'autoxray help | grep -q doctor'

step "Бэкап и повторный render идемпотентен"
autoxray backup /tmp/bk.tar.gz >/dev/null && check "бэкап создан" test -s /tmp/bk.tar.gz
md5_before=$(md5sum /usr/local/etc/xray/config.json | cut -d' ' -f1)
autoxray render
[ "$md5_before" = "$(md5sum /usr/local/etc/xray/config.json | cut -d' ' -f1)" ] && pass "повторный render ничего не меняет" || fail "render не идемпотентен (dummy-ключи?)"

finish
