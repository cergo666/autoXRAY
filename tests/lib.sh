#!/bin/bash
# Общие функции e2e-тестов (выполняются внутри контейнера autoxray-test).
# shellcheck disable=SC2034

GRN='\033[1;32m'; RED='\033[1;31m'; YEL='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

step()  { echo -e "\n${YEL}▶ $*${NC}"; }
pass()  { PASS=$((PASS + 1)); echo -e "  ${GRN}✔${NC} $*"; }
fail()  { FAIL=$((FAIL + 1)); echo -e "  ${RED}✘ $*${NC}"; }
check() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }
finish() {
    echo -e "\n=== итог: ${GRN}$PASS ok${NC}, ${RED}$FAIL fail${NC} ==="
    [ "$FAIL" -eq 0 ]
}

# Статус пользователя (active|limit|expired|disabled) из машиночитаемого списка
ustatus() { autoxray user list --plain | awk -F'\t' -v n="$1" '$1 == n {print $2}'; }

# Локальный CA и сертификат для домена (доверяем CA на уровне системы — клиент Xray проверяет TLS по-настоящему)
setup_tls() { # домен [каталог общего CA]
    local domain=$1 ca=${2:-/tmp/ca}
    mkdir -p "$ca" /var/lib/xray/cert
    if [ ! -f "$ca/ca.pem" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=autoxray-test-ca" \
            -keyout "$ca/ca.key" -out "$ca/ca.pem" 2>/dev/null
    fi
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$domain" \
        -keyout /var/lib/xray/cert/privkey.pem -out /tmp/srv.csr 2>/dev/null
    printf 'subjectAltName=DNS:%s\n' "$domain" > /tmp/san.cnf
    openssl x509 -req -in /tmp/srv.csr -CA "$ca/ca.pem" -CAkey "$ca/ca.key" -CAcreateserial -days 30 -extfile /tmp/san.cnf \
        -out /var/lib/xray/cert/fullchain.pem 2>/dev/null
    cp "$ca/ca.pem" /usr/local/share/ca-certificates/autoxray-test-ca.crt
    update-ca-certificates >/dev/null 2>&1
    chmod 644 /var/lib/xray/cert/*.pem
}

# Установка CLI и шаблонов из каталога репозитория так же, как это делает install.sh
install_cli() {
    install -m 755 /opt/autoxray/autoxray /usr/local/bin/autoxray
    mkdir -p /usr/local/share/autoxray/telegram
    install -m 644 /opt/autoxray/templates/sub.html /opt/autoxray/templates/nginx.conf /opt/autoxray/templates/report.html /usr/local/share/autoxray/
}

# Профиль i из подписки пользователя -> клиентский конфиг, адрес сервера заменён на $2 (DNS в тесте не нужен)
client_cfg() { # токен индекс адрес
    jq --argjson i "$2" --arg a "$3" '.[$i] | .outbounds[0].settings |= (if .vnext then .vnext[0].address = $a else .address = $a end)' \
        "/var/www/$DOMAIN/$1.json"
}

# Запуск клиентского Xray на socks 10808, ждём порт
client_start() { # конфиг-файл
    client_stop
    nohup setsid xray run -c "$1" >/tmp/client.out 2>&1 &
    echo $! > /run/xray-client.pid
    for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q '127.0.0.1:10808' && return 0; sleep 0.2; done
    echo "клиент не поднялся:"; tail -n 20 /tmp/client.out; return 1
}
client_stop() { [ -f /run/xray-client.pid ] && kill "$(cat /run/xray-client.pid)" 2>/dev/null; rm -f /run/xray-client.pid; sleep 0.3; }

# Запрос к «внешнему» серверу через клиентский прокси
via_proxy() { # файл — с тремя попытками: клиент Xray может «прогреваться» первые секунды
    local i
    for i in 1 2 3; do
        curl -fsS --max-time 12 --socks5-hostname 127.0.0.1:10808 "http://93.184.216.34:8080/${1:-ok.txt}" && return 0
        sleep 1
    done
    return 1
}

# Внешняя «цель»: адрес из публичный адрес, не RU и не private на lo и простой http-сервер
start_target() {
    ip addr add 93.184.216.34/32 dev lo 2>/dev/null || true
    mkdir -p /srv/target; echo "TARGET-OK" > /srv/target/ok.txt
    (cd /srv/target && nohup python3 -m http.server 8080 --bind 93.184.216.34 >/tmp/target.out 2>&1 &)
    local i
    for i in $(seq 1 50); do curl -fsS --max-time 2 http://93.184.216.34:8080/ok.txt >/dev/null 2>&1 && return 0; sleep 0.2; done
    echo "target не поднялся"; return 1
}
