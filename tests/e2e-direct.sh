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

step "Режим российских сайтов у каждого пользователя"
autoxray user add carl --ru server >/dev/null && pass "carl создан с --ru server" || fail "user add carl"
TOKEN_C=$(jq -r '.users[] | select(.name=="carl").token' /etc/autoxray/state.json)
TOKEN_A=$(jq -r '.users[] | select(.name=="alice").token' /etc/autoxray/state.json)
has_ru_direct() { jq -e '.[0].routing.rules | map(.ip // [] | index("geoip:ru")) | any(. != null)' "$WEB/$1.json" >/dev/null; }
has_ru_direct "$TOKEN_A" && pass "alice (ru direct): российские сайты в подписке идут напрямую" || fail "alice: нет direct для RU"
has_ru_direct "$TOKEN_C" && fail "carl (ru server): в подписке остался direct для RU" || pass "carl (ru server): российские сайты уходят на сервер"
autoxray user set carl --ru direct >/dev/null; has_ru_direct "$TOKEN_C" && pass "carl переключён в direct" || fail "carl не переключился"
autoxray user list --plain | awk -F'\t' '$1=="carl" && $7=="direct"' | grep -q . && pass "plain-вывод содержит режим RU" || fail "plain без режима RU"
autoxray user link alice --plain | head -n1 | grep -q 'для моста' && fail "в названии XHTTP осталась приписка «для моста»" || pass "название XHTTP без приписки «для моста»"
autoxray user del carl >/dev/null

step "Лимит IP: второй адрес блокируется, первый продолжает работать"
check "ipwatch_parse: tcp:, IPv6, пропуск блокировок и строк без email" bash -c '
  source <(sed -n "/^ipwatch_parse()/,/^}/p" /opt/autoxray/autoxray)
  out=$(printf "%s\n" \
    "x from 1.2.3.4:5 accepted tcp:a:1 [i >> d] email: u1" \
    "x from tcp:5.6.7.8:9 accepted tcp:a:1 [i >> d] email: u1" \
    "x from [2001:db8::1]:77 accepted tcp:a:1 [i >> d] email: u2" \
    "x from 9.9.9.9:1 accepted tcp:a:1 [i -> block] email: u1" \
    "x from 7.7.7.7:1 accepted tcp:a:1 [socks >> d]" | ipwatch_parse | tr "\n" ";")
  [ "$out" = "u1 1.2.3.4;u1 5.6.7.8;u2 2001:db8::1;" ]'
autoxray user add dan --ips 1 >/dev/null || fail "user add dan"
TOKEN_D=$(jq -r '.users[] | select(.name=="dan").token' /etc/autoxray/state.json)
[ "$(jq -r .log.loglevel /usr/local/etc/xray/config.json)" = warning ] && pass "лог доступа включился вместе с лимитом IP" || fail "лог доступа не включён"
client_cfg "$TOKEN_D" 1 127.0.0.1 > /tmp/d1.json
jq '.outbounds[0].sendThrough = "127.0.0.2"' /tmp/d1.json > /tmp/d2.json
: > /var/log/xray/access.log
client_start /tmp/d1.json && via_proxy ok.txt >/dev/null && pass "dan: первый IP (127.0.0.1) работает" || fail "dan: первый IP"
client_start /tmp/d2.json && via_proxy ok.txt >/dev/null && pass "dan: второй IP (127.0.0.2) до проверки проходит" || fail "dan: второй IP до проверки"
autoxray ipwatch | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'лишний IP 127.0.0.2' && pass "ipwatch заблокировал лишний IP" || fail "ipwatch не заблокировал"
jq -e '.routing.rules[] | select(.user == ["dan"] and .source == ["127.0.0.2"] and .outboundTag == "block")' /usr/local/etc/xray/config.json >/dev/null && pass "правило user+source в конфиге Xray" || fail "нет правила блокировки"
check "xray -test с правилом блокировки" xray run -test -c /usr/local/etc/xray/config.json
client_start /tmp/d2.json; curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:10808 http://93.184.216.34:8080/ok.txt >/dev/null 2>&1 && fail "заблокированный IP всё ещё проходит" || pass "заблокированный IP не проходит"
client_start /tmp/d1.json && via_proxy ok.txt >/dev/null && pass "dan: первый IP продолжает работать" || fail "dan: первый IP сломался"
autoxray ips dan | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'заблокирован' && pass "autoxray ips показывает блокировку" || fail "ips без блокировки"
autoxray unban dan >/dev/null && client_start /tmp/d2.json && via_proxy ok.txt >/dev/null && pass "после unban второй IP снова проходит" || fail "unban"
client_stop
autoxray user set dan --ips 0 >/dev/null; [ "$(jq -r .log.loglevel /usr/local/etc/xray/config.json)" = none ] && pass "без лимитов лог доступа снова выключен" || fail "лог доступа остался включён"
autoxray user del dan >/dev/null

step "Отчёты о посещениях: сбор, агрегация, html, доступ по секретному адресу"
check "report_parse чистит имена хостов (защита от внедрения html)" bash -c '
  source <(sed -n "/^report_parse()/,/^}/p" /opt/autoxray/autoxray)
  out=$(printf "%s\n" "2026/10/16 10:00:00.1 from 1.2.3.4:5 accepted tcp:<script>alert(1)</script>.evil.com:443 [i >> direct] email: u1" | report_parse)
  case "$out" in *"<"*|*">"*|*"("*) exit 1 ;; esac; [ -n "$out" ]'
autoxray user add erin --report on >/tmp/erin.out 2>&1 && pass "erin создан с отчётом" || { fail "user add erin --report on"; cat /tmp/erin.out; }
RT=$(jq -r '.reports.token' /etc/autoxray/state.json); [ ${#RT} = 32 ] && pass "выдан секретный токен отчётов" || fail "токен отчётов: '$RT'"
grep -q "location ^~ /r/$RT/" /etc/nginx/conf.d/default.conf && pass "nginx: блок отчётов добавлен" || fail "в nginx нет блока отчётов"
check "nginx -t с блоком отчётов" nginx -t
[ "$(jq -r .log.loglevel /usr/local/etc/xray/config.json)" = warning ] && pass "лог доступа включён ради отчёта" || fail "лог доступа не включён"
TOKEN_E=$(jq -r '.users[] | select(.name=="erin").token' /etc/autoxray/state.json)
for _ in 1 2 3 4 5 6 7 8 9 10; do   # nginx -s reload асинхронный: воркеры подхватывают конфиг не мгновенно
  code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/r/$RT/erin/"); [ "$code" = 200 ] && break; sleep 0.5
done
[ "$code" = 200 ] && pass "страница отчёта открывается по секретному адресу" || fail "страница отчёта: $code"
code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/r/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ/erin/"); [ "$code" = 404 ] && pass "чужой токен отчётов даёт 404" || fail "чужой токен отчётов: $code"
client_cfg "$TOKEN_E" 1 127.0.0.1 > /tmp/e1.json
: > /var/log/xray/access.log
client_start /tmp/e1.json
curl -sS -o /dev/null --max-time 15 --socks5-hostname 127.0.0.1:10808 http://example.com/ || true
for _ in 1 2; do via_proxy ok.txt >/dev/null; done
client_stop
autoxray ipwatch
EDAY=$(ls /etc/autoxray/reports/erin/*.json 2>/dev/null | head -n1)
[ -n "$EDAY" ] && pass "суточный файл данных создан" || fail "нет суточного файла"
jq -e '.total >= 2 and (.hosts | has("93.184.216.34")) and (.src | has("127.0.0.1")) and (.out.direct >= 2) and (.hours | length == 24)' "$EDAY" >/dev/null && pass "агрегаты: адрес назначения, IP клиента, выход, часы" || { fail "агрегаты не сошлись"; jq -c . "$EDAY"; }
jq -e '.hosts | has("example.com")' "$EDAY" >/dev/null && pass "в отчёте виден домен, который запросил клиент" || { fail "домен example.com не попал в отчёт"; jq -c '.hosts' "$EDAY"; }
autoxray report build erin >/dev/null
curl -fsS --max-time 8 "https://$DOMAIN/r/$RT/erin/" -o /tmp/report.html
grep -q '93.184.216.34' /tmp/report.html && ! grep -q '</script>.evil' /tmp/report.html && pass "html отчёта содержит данные и безопасен" || fail "html отчёта"
[ "$(stat -c %a /etc/autoxray/reports)" = 700 ] && pass "данные отчётов закрыты (700)" || fail "права данных отчётов"
echo '{"date":"2000-01-01","total":1,"hosts":{"old.test":1},"hours":[]}' > /etc/autoxray/reports/erin/2000-01-01.json
autoxray report keep 7 >/dev/null; [ ! -e /etc/autoxray/reports/erin/2000-01-01.json ] && pass "старые дни удаляются по сроку хранения" || fail "retention не сработал"
autoxray user set erin --report off >/dev/null 2>&1
[ ! -d /var/lib/autoxray/reports/erin ] && pass "после выключения папка отчёта удалена" || fail "папка отчёта осталась"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$DOMAIN/r/$RT/erin/"); [ "$code" = 404 ] && break; sleep 0.5
done
[ "$code" = 404 ] && pass "после выключения адрес отчёта не отдаётся" || fail "адрес отчёта: $code"
[ "$(jq -r .log.loglevel /usr/local/etc/xray/config.json)" = none ] && pass "лог доступа снова выключен" || fail "лог доступа остался"
autoxray report purge erin >/dev/null; [ ! -d /etc/autoxray/reports/erin ] && pass "purge удаляет накопленные данные" || fail "purge"
autoxray user del erin >/dev/null

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
has_ru_direct "$TOKEN_A" && pass "warp ru on не меняет подписку пользователя в режиме direct" || fail "warp ru on изменил подписку"
autoxray user set alice --ru server >/dev/null
has_ru_direct "$TOKEN_A" && fail "alice с --ru server: RU остался direct" || pass "alice с --ru server: российские сайты идут на сервер"
client_cfg "$TOKEN_A" 1 127.0.0.1 > /tmp/client-w.json
client_start /tmp/client-w.json && via_proxy ok.txt >/dev/null && pass "трафик идёт при включённом WARP (не-RU напрямую)" || fail "трафик сломан при WARP"
client_stop
autoxray warp ru off >/dev/null && check "warp ru off + xray -test" xray run -test -c /usr/local/etc/xray/config.json
autoxray warp off >/dev/null && check "warp off + xray -test" xray run -test -c /usr/local/etc/xray/config.json

step "Логи: без лимитов очищаются, при превышении размера обнуляются"
echo junk > /var/log/xray/access.log; echo junk > /var/log/xray/error.log
autoxray ipwatch; { [ ! -s /var/log/xray/access.log ] && [ ! -s /var/log/xray/error.log ]; } && pass "без лимитов IP логи очищаются" || fail "логи не очищены"
autoxray user add eve --ips 1 >/dev/null
head -c 5000 /dev/urandom | base64 > /var/log/xray/error.log
AX_LOG_MAX=1000 autoxray ipwatch; [ ! -s /var/log/xray/error.log ] && pass "превышение размера обнуляет лог" || fail "большой лог не обнулён"
autoxray user del eve >/dev/null

step "WARP: сканер endpoint'ов (ранжирование, кандидаты, отказ без ответа)"
check "warp_rank: сортировка и фильтры по узлам" bash -c '
  source <(sed -n "/^warp_rank()/,/^}/p" /opt/autoxray/autoxray)
  tsv=$(printf "120\ta:1\tFRA\tDE\t3\n40\tb:1\tDME\tRU\t3\n80\tc:1\tAMS\tNL\t2\n")
  [ "$(printf "%s\n" "$tsv" | warp_rank "" "" | cut -f2 | tr "\n" " ")" = "b:1 c:1 a:1 " ] &&
  [ "$(printf "%s\n" "$tsv" | warp_rank "" "DME" | cut -f2 | tr "\n" " ")" = "c:1 a:1 " ] &&
  [ "$(printf "%s\n" "$tsv" | warp_rank "FRA,AMS" "" | cut -f2 | tr "\n" " ")" = "c:1 a:1 " ]'
[ "$(autoxray warp candidates quick | grep -cE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:2408$")" -ge 14 ] && pass "кандидаты: по адресу из каждого диапазона Cloudflare" || fail "кандидаты quick"
[ "$(autoxray warp candidates ports | wc -l)" = 9 ] && pass "кандидаты: запасные порты 500, 1701, 4500" || fail "кандидаты ports"
AX_WARP_CANDIDATES="162.159.192.1:2408 188.114.97.1:2408" autoxray warp scan >/tmp/scan.out 2>&1 && fail "scan «нашёл» рабочий endpoint с поддельным профилем" || pass "scan честно сообщает, что ни один endpoint не ответил"

step "WARP: глубина сканирования и ночная проверка (поддельные результаты замера)"
[ "$(autoxray warp candidates more | wc -l)" -ge 270 ] && pass "глубина more: около 280 адресов" || fail "candidates more: $(autoxray warp candidates more | wc -l)"
[ "$(autoxray warp candidates all | wc -l)" -ge 3550 ] && pass "глубина all: все адреса диапазонов (около 3500)" || fail "candidates all: $(autoxray warp candidates all | wc -l)"
printf '120\t1.1.1.1:2408\tFRA\tDE\t3\t3\t30\t100,120,140\n250\t2.2.2.2:2408\tAMS\tNL\t3\t3\t35\t200,250,300\n10040\t9.9.9.9:2408\tDME\tRU\t0\t3\t40\t-,-,-\n' > /tmp/fake1.tsv
AX_WARP_FAKE_RESULTS=/tmp/fake1.tsv autoxray warp scan 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > /tmp/scan-fake.out
grep -q 'yandex' /tmp/scan-fake.out && grep -q '1.1.1.1:2408' /tmp/scan-fake.out && grep -q 'RU ✘' /tmp/scan-fake.out && pass "таблица: отклик по российским сайтам и отметка недоступных" || { fail "таблица сканера"; cat /tmp/scan-fake.out; }
AX_WARP_FAKE_RESULTS=/tmp/fake1.tsv autoxray warp scan --exclude-colo FRA 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q '2.2.2.2' && pass "scan --exclude-colo учитывает фильтр" || fail "фильтр по узлам"
autoxray warp nightly on >/dev/null; autoxray warp threshold 300 >/dev/null
autoxray warp on --force >/dev/null 2>&1
AX_WARP_FAKE_RESULTS=/tmp/fake1.tsv autoxray warp rescan now >/dev/null 2>&1
[ "$(jq -r .warp.endpoint /etc/autoxray/state.json)" = "1.1.1.1:2408" ] && pass "ночная проверка: выбран самый быстрый (1.1.1.1:2408)" || fail "rescan: endpoint $(jq -r .warp.endpoint /etc/autoxray/state.json)"
[ "$(jq '.warp.top | length' /etc/autoxray/state.json)" = 3 ] && pass "топ сохранён в настройках" || fail "топ не сохранён"
grep -q 'режим full' /etc/autoxray/warp-rescan.log && pass "без сохранённого топа сделан полный проход" || fail "лог: $(tail -n1 /etc/autoxray/warp-rescan.log)"
check "xray -test после смены endpoint" xray run -test -c /usr/local/etc/xray/config.json
printf '90\t3.3.3.3:2408\tAMS\tNL\t3\t3\t30\t80,90,100\n' > /tmp/fake2.tsv
AX_WARP_FAKE_RESULTS=/tmp/fake2.tsv autoxray warp rescan now >/dev/null 2>&1
[ "$(jq -r .warp.endpoint /etc/autoxray/state.json)" = "3.3.3.3:2408" ] && grep -q 'режим top' /etc/autoxray/warp-rescan.log && pass "топ быстрее порога: берётся лучший из топа, полный проход не нужен" || fail "rescan по топу: $(tail -n1 /etc/autoxray/warp-rescan.log)"
printf '100\t3.3.3.3:2408\tAMS\tNL\t3\t3\t30\t90,100,110\n95\t4.4.4.4:2408\tFRA\tDE\t3\t3\t30\t90,95,100\n' > /tmp/fake3.tsv
AX_WARP_FAKE_RESULTS=/tmp/fake3.tsv autoxray warp rescan now >/dev/null 2>&1
[ "$(jq -r .warp.endpoint /etc/autoxray/state.json)" = "3.3.3.3:2408" ] && pass "небольшой выигрыш не меняет endpoint (без лишнего перезапуска Xray)" || fail "гистерезис: $(jq -r .warp.endpoint /etc/autoxray/state.json)"
printf '450\t5.5.5.5:2408\tFRA\tDE\t3\t3\t30\t400,450,500\n' > /tmp/fake4.tsv
AX_WARP_FAKE_RESULTS=/tmp/fake4.tsv autoxray warp rescan now >/dev/null 2>&1
grep -q 'режим full' <(tail -n1 /etc/autoxray/warp-rescan.log) && pass "все медленнее порога: выполнен полный проход" || fail "порог: $(tail -n1 /etc/autoxray/warp-rescan.log)"
autoxray warp nightly off >/dev/null; before=$(jq -r .warp.endpoint /etc/autoxray/state.json)
AX_WARP_FAKE_RESULTS=/tmp/fake2.tsv autoxray warp rescan >/dev/null 2>&1
[ "$before" = "$(jq -r .warp.endpoint /etc/autoxray/state.json)" ] && pass "при выключенной ночной проверке cron ничего не меняет" || fail "rescan сработал при nightly off"
autoxray warp off >/dev/null

step "Версии: баннер обновления и список версий ядра (поддельный GitHub API)"
mkdir -p /tmp/api/repos/cergo666/autoXRAY/releases /tmp/api/repos/XTLS/Xray-core
echo '{"tag_name":"v99.0.0"}' > /tmp/api/repos/cergo666/autoXRAY/releases/latest
echo '[{"tag_name":"v99.1.0","prerelease":false,"draft":false},{"tag_name":"v100.0.0","prerelease":true,"draft":false},{"tag_name":"v26.9.9","prerelease":false,"draft":false}]' > /tmp/api/repos/XTLS/Xray-core/releases
rm -f /etc/autoxray/.latest
AX_API=file:///tmp/api autoxray status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q 'Доступна версия 99.0.0' && pass "баннер: доступна новая версия autoxray" || fail "баннера обновления нет"
AX_API=file:///tmp/api autoxray core list 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > /tmp/core.out
grep -q 'v99.1.0' /tmp/core.out && grep -q 'v100.0.0.*пререлиз' /tmp/core.out && ! grep -q 'v99.1.0.*пререлиз' /tmp/core.out && pass "core list: новее текущей, пререлиз помечен" || { fail "core list"; cat /tmp/core.out; }
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

step "Универсальная подписка (base64 со ссылками)"
TOKEN_A=$(jq -r '.users[] | select(.name=="alice").token' /etc/autoxray/state.json)
curl -sS --max-time 8 -D /tmp/h2.txt -o /tmp/sub.txt "https://$DOMAIN/$TOKEN_A.txt"
base64 -d < /tmp/sub.txt > /tmp/sub.links 2>/dev/null
[ "$(wc -l < /tmp/sub.links)" -ge 3 ] && grep -q '^vless://' /tmp/sub.links && grep -q '^hy2://' /tmp/sub.links && pass "подписка .txt: base64 со ссылками vless и hy2" || { fail "подписка .txt"; head -c 300 /tmp/sub.links; }
grep -qi '^subscription-userinfo:' /tmp/h2.txt && pass "у .txt есть subscription-userinfo" || fail "нет subscription-userinfo у .txt"
curl -fsS --max-time 8 "https://$DOMAIN/$TOKEN_A.html" | grep -q "$TOKEN_A.txt" && pass "на личной странице есть универсальная подписка" || fail "страница без .txt"
autoxray user qr alice links >/dev/null 2>&1 && pass "user qr links" || fail "user qr links"

step "Сайт-маскировка: пересоздание и свой сайт"
md5_a=$(md5sum "$WEB/index.html" | cut -d' ' -f1)
autoxray site regenerate >/dev/null && [ "$md5_a" != "$(md5sum "$WEB/index.html" | cut -d' ' -f1)" ] && pass "site regenerate даёт новый сайт" || fail "site regenerate"
mkdir -p /tmp/mysite && echo '<html><body>MYSITE-MARKER</body></html>' > /tmp/mysite/index.html
autoxray site set /tmp/mysite >/dev/null 2>&1 && curl -fsS --max-time 8 "https://$DOMAIN/" | grep -q MYSITE-MARKER && pass "site set: отдаётся свой сайт" || fail "site set"
curl -fsS --max-time 8 "https://$DOMAIN/$TOKEN_A.json" >/dev/null && pass "подписки продолжают работать со своим сайтом" || fail "подписка после site set"
autoxray site status | sed 's/\x1b\[[0-9;]*m//g' | grep -q custom && pass "site status показывает режим custom" || fail "site status"
autoxray site regenerate >/dev/null

step "Безопасное обновление: снимок, успешное обновление, откат при сбое"
ORIG_VER=$(autoxray version | awk '{print $2}')
mk_release() { # версия [постфикс-код]
  rm -rf "/tmp/rel/v$1"; mkdir -p "/tmp/rel/v$1"; cp -r /opt/autoxray/templates /opt/autoxray/components "/tmp/rel/v$1/"
  sed "s/^AX_VERSION=\".*\"/AX_VERSION=\"$1\"/" /opt/autoxray/autoxray > "/tmp/rel/v$1/autoxray"
  [ -n "${2:-}" ] && sed -i "s|^main \"\$@\"\$|$2\nmain \"\$@\"|" "/tmp/rel/v$1/autoxray"
  return 0
}
mk_release 9.9.9
AX_RAW_BASE=file:///tmp/rel autoxray self-update v9.9.9 >/tmp/upd1.out 2>&1 && [ "$(autoxray version | awk '{print $2}')" = 9.9.9 ] && pass "self-update до 9.9.9 прошёл проверки" || { fail "self-update"; sed 's/\x1b\[[0-9;]*m//g' /tmp/upd1.out | tail -n 8; }
ls /var/lib/autoxray/snapshots/*-v$ORIG_VER.tar.gz >/dev/null 2>&1 && pass "перед обновлением создан снимок" || fail "снимка нет"
mk_release 9.9.8 'post_update_check() { return 1; }'
state_md5=$(md5sum /etc/autoxray/state.json | cut -d' ' -f1)
AX_RAW_BASE=file:///tmp/rel autoxray self-update v9.9.8 >/tmp/upd2.out 2>&1 && fail "сломанное обновление не должно проходить" || pass "сломанное обновление отклонено"
[ "$(autoxray version | awk '{print $2}')" = 9.9.9 ] && pass "после неудачи версия вернулась (9.9.9)" || fail "версия после отката: $(autoxray version)"
[ "$state_md5" = "$(md5sum /etc/autoxray/state.json | cut -d' ' -f1)" ] && pass "state.json не изменился после отката" || fail "state.json изменился"
curl -fsS --max-time 8 "https://$DOMAIN/$TOKEN_A.json" >/dev/null && pass "после отката подписка работает" || fail "подписка после отката"
printf 'y\n' | autoxray rollback 2 >/tmp/rb.out 2>&1; [ "$(autoxray version | awk '{print $2}')" = "$ORIG_VER" ] && pass "rollback возвращает исходную версию ($ORIG_VER)" || { fail "rollback: $(autoxray version)"; tail -n 5 /tmp/rb.out; }
install_cli

step "Telegram-бот: команды администратора, подтверждения, уведомления (поддельный Telegram API)"
TG=/tmp/tg; rm -rf "$TG"; mkdir -p "$TG"
python3 /opt/autoxray/tests/mock_telegram.py 8081 "$TG" & MOCK=$!
sleep 1
export AX_TG_API=http://127.0.0.1:8081 AX_TG_POLL=1 AX_TG_TIMEOUT=10
TOK=123456:TESTTOKENTESTTOKENTESTTOKEN12
autoxray bot setup --token "$TOK" --admin 111 >/tmp/bot-setup.out 2>&1 && pass "bot setup: токен принят, администратор добавлен" || { fail "bot setup"; sed 's/\x1b\[[0-9;]*m//g' /tmp/bot-setup.out; }
[ "$(stat -c %a /etc/autoxray/bot.token)" = 600 ] && pass "токен бота хранится с правами 600" || fail "права токена"
jq -e '.bot.enabled == true and .bot.admins == [111]' /etc/autoxray/state.json >/dev/null && pass "в настройках только admin 111" || fail "настройки бота"
grep -q 'ExecStart=.*autoxray bot run' /etc/systemd/system/autoxray-bot.service && pass "создан unit autoxray-bot.service" || fail "unit не создан"
autoxray bot run >/tmp/bot-run.out 2>&1 & BOT=$!
sleep 2
qn=0
tgmsg() { qn=$((qn + 1)); jq -nc --argjson i $qn --argjson f "$1" --arg t "$2" '{update_id: $i, message: {message_id: $i, from: {id: $f, first_name: "T"}, chat: {id: $f, type: "private"}, text: $t}}' >> "$TG/queue.jsonl"; }
tgcb() { qn=$((qn + 1)); jq -nc --argjson i $qn --argjson f "$1" --arg d "$2" '{update_id: $i, callback_query: {id: ("cb" + ($i | tostring)), from: {id: $f}, message: {message_id: 7, chat: {id: $f, type: "private"}}, data: $d}}' >> "$TG/queue.jsonl"; }
sent_has() { for _ in $(seq 1 30); do jq -e --arg p "$1" 'select((.payload.text // "") | test($p))' "$TG/sent.jsonl" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
sent_method() { for _ in $(seq 1 30); do jq -e --arg m "$1" 'select(.method == $m)' "$TG/sent.jsonl" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

tgmsg 111 /status;  sent_has "autoXRAY" && pass "/status отвечает администратору" || fail "/status"
tgmsg 222 /status;  tgmsg 222 /users; sleep 3
[ "$(jq -s '[.[] | select(.method == "sendMessage" and .payload.chat_id == 222)] | length' "$TG/sent.jsonl")" = 0 ] && pass "постороннему бот не отвечает" || fail "бот ответил постороннему"
tgmsg 222 /id;      sent_has "222" && pass "/id работает у всех и показывает ID" || fail "/id"
sent_kb() { for _ in $(seq 1 30); do jq -e --arg d "$1" 'select(.method == "sendMessage") | .payload.reply_markup.inline_keyboard[][] | select(.callback_data == $d)' "$TG/sent.jsonl" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
tgmsg 111 /users;   sent_kb "u:alice" && pass "/users: кнопка пользователя alice" || fail "/users"
tgmsg 111 "/add frank 5 7"; sent_has "создан" && jq -e '.users[] | select(.name == "frank" and .limit == 5368709120 and .expire > 0)' /etc/autoxray/state.json >/dev/null && pass "/add создал frank с лимитом и сроком" || fail "/add frank"
tgmsg 111 "/add bad!name"; sent_has "Имя:" && ! jq -e '.users[] | select(.name == "bad!name")' /etc/autoxray/state.json >/dev/null && pass "неверное имя отклонено" || fail "проверка имени"
tgmsg 111 '/add x;touch /tmp/pwned 1'; sleep 2; [ ! -e /tmp/pwned ] && pass "внедрение команд через аргументы невозможно" || fail "ВНЕДРЕНИЕ КОМАНДЫ"
tgmsg 111 "/limit frank 10"; sleep 2; [ "$(jq '.users[] | select(.name == "frank") | .limit' /etc/autoxray/state.json)" = 10737418240 ] && pass "/limit меняет лимит" || fail "/limit"
tgcb 111 "u:frank:lim:50"; sleep 2; [ "$(jq '.users[] | select(.name == "frank") | .limit' /etc/autoxray/state.json)" = 53687091200 ] && pass "кнопка лимита 50 ГБ" || fail "кнопка лимита"
tgcb 111 "u:frank:tog"; sleep 2; [ "$(jq '.users[] | select(.name == "frank") | .enabled' /etc/autoxray/state.json)" = false ] && pass "кнопка отключения" || fail "кнопка отключения"
tgcb 111 "u:alice:qr"; sent_method sendPhoto && pass "QR отправляется картинкой" || fail "sendPhoto"
tgcb 111 "u:alice:links"; sent_has "vless://" && pass "кнопка «Ссылки» присылает ссылки" || fail "ссылки"
tgcb 111 "u:frank:del"; sent_method editMessageText; sleep 2
jq -e '.users[] | select(.name == "frank")' /etc/autoxray/state.json >/dev/null && pass "удаление требует подтверждения (пользователь ещё есть)" || fail "удалился без подтверждения"
tgcb 222 "u:frank:delok"; sleep 2
jq -e '.users[] | select(.name == "frank")' /etc/autoxray/state.json >/dev/null && pass "callback постороннего игнорируется" || fail "посторонний удалил пользователя"
tgcb 111 "u:frank:delok"; sleep 3
jq -e '.users[] | select(.name == "frank")' /etc/autoxray/state.json >/dev/null && fail "подтверждённое удаление не сработало" || pass "подтверждённое удаление работает"
! pgrep -af "TESTTOKEN" >/dev/null && pass "токен не виден в списке процессов" || fail "токен в аргументах процесса"
! grep -q TESTTOKEN /tmp/bot-run.out && pass "токен не попадает в журнал бота" || fail "токен в журнале"

# уведомления: у пользователя заканчивается лимит
autoxray user add hank --limit 1 >/dev/null
autoxray collect >/dev/null 2>&1          # первая проверка запоминает статусы (hank активен)
jq '.hank = {up: 2000000000, down: 2000000000}' /etc/autoxray/traffic.json > /tmp/tr.json && cp /tmp/tr.json /etc/autoxray/traffic.json
autoxray collect >/dev/null 2>&1          # лимит превышен: приходит уведомление
sent_has "hank.*лимит" && pass "уведомление: исчерпан лимит трафика" || fail "уведомление о лимите"
autoxray bot test >/dev/null 2>&1; sent_has "Проверка уведомлений" && pass "bot test присылает уведомление администратору" || fail "bot test"
autoxray user del hank >/dev/null
kill "$BOT" 2>/dev/null; wait "$BOT" 2>/dev/null
autoxray bot remove >/dev/null 2>&1; [ ! -e /etc/autoxray/bot.token ] && pass "bot remove удаляет токен" || fail "токен остался"
kill "$MOCK" 2>/dev/null; unset AX_TG_API AX_TG_POLL AX_TG_TIMEOUT

step "Бэкап и повторный render идемпотентен"
autoxray backup /tmp/bk.tar.gz >/dev/null && check "бэкап создан" test -s /tmp/bk.tar.gz
md5_before=$(md5sum /usr/local/etc/xray/config.json | cut -d' ' -f1)
autoxray render
[ "$md5_before" = "$(md5sum /usr/local/etc/xray/config.json | cut -d' ' -f1)" ] && pass "повторный render ничего не меняет" || fail "render не идемпотентен (dummy-ключи?)"

finish
