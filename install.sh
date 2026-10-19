#!/bin/bash
# autoXRAY — установщик: selfsteal VLESS RAW/XHTTP + Hysteria2 + Web Proxy Telegram
# с несколькими пользователями (CLI `autoxray`) и опциональным WARP.
#
# Запуск:  bash -c "$(curl -L https://github.com/cergo666/autoXRAY/releases/latest/download/install.sh)" -- домен.com
# Мост RU -> EU: добавьте vless:// ссылки EU-серверов после домена (XHTTP/RAW TLS):
#          ... -- домен.com "vless://..." "vless://..."
# Автоматизация (без вопросов): AX_TG=y|n AX_FP=1..8 AX_USER=имя AX_WARP=n|y|ru bash install.sh домен.com
# Отладка из локальной копии репозитория: AUTOXRAY_SRC=/путь/к/репозиторию

GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
MAG='\033[1;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

AX_RELEASE="3.10.0"
AX_REF_DEFAULT="main"   # при выпуске релиза заменяется на тег (см. .github/workflows/release.yml)
AX_REF="${AUTOXRAY_REF:-$AX_REF_DEFAULT}"
RAW="https://raw.githubusercontent.com/cergo666/autoXRAY/$AX_REF"
XRAY_VERSION="${AX_XRAY_VERSION:-v26.9.9}"

echo -e "${GRN}autoXRAY $AX_RELEASE (источник: $AX_REF) ${NC}"
sleep 1

die() { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Скрипту нужны root права!"

. /etc/os-release 2>/dev/null
[[ "$ID" =~ ^(debian|ubuntu)$ ]] || die "Поддерживаются только Debian и Ubuntu!"
[[ "$ID" == "ubuntu" ]] && echo -e "${YEL}⚠️ Внимание: запуск на Ubuntu. Рекомендованная система: Debian 12/13.${NC}"

DOMAIN=$1
[[ -n "$DOMAIN" ]] || die "Домен не задан. Пример: bash install.sh vpn.example.com"
shift
VLESS_URLS=("$@")
INIT_MODE=direct
INIT_NODES=()
if [ ${#VLESS_URLS[@]} -gt 0 ]; then
    INIT_MODE=bridge
    for u in "${VLESS_URLS[@]}"; do
        [[ "$u" == vless://* ]] || die "Неверная ссылка (ожидается vless://...): $u"
        INIT_NODES+=(--node "$u")
    done
    echo -e "${GRN}Режим моста RU -> EU, узлов: ${#VLESS_URLS[@]}${NC}"
fi
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Недопустимое имя домена: $DOMAIN"
# повторная установка: режим берётся из прежней (в режиме моста вопросы про WARP не нужны)
if [ -f /etc/autoxray/state.json ] && command -v jq >/dev/null && [ "$(jq -r '.mode // "direct"' /etc/autoxray/state.json 2>/dev/null)" = bridge ]; then
    INIT_MODE=bridge
fi

# fetch <путь в репозитории> — печатает файл в stdout (локальная копия или raw.githubusercontent)
fetch() {
    if [[ -n "$AUTOXRAY_SRC" ]]; then cat "$AUTOXRAY_SRC/$1"; else curl -fsSL --retry 2 "$RAW/$1"; fi
}

# ask <ПЕРЕМЕННАЯ> <вопрос> <по умолчанию> — если переменная уже задана в окружении, не спрашиваем
ask() {
    local var=$1 prompt=$2 def=$3 val
    if [[ -n "${!var}" ]]; then return; fi
    read -r -p "$(echo -e "${YEL}${prompt}${NC} ")" val
    printf -v "$var" '%s' "${val:-$def}"
}

# ==========================================
# Пакеты и nginx
# ==========================================
KEYRING_PKG=$([ "$ID" = "ubuntu" ] && echo "ubuntu-keyring" || echo "debian-archive-keyring")

echo -e "${YEL}Подготовка официального репозитория Nginx для $ID ($VERSION_CODENAME)...${NC}"
apt-get update || die "apt-get update не выполнен"
apt-get install -y curl gnupg2 ca-certificates lsb-release "$KEYRING_PKG" jq dnsutils openssl wget tar socat cron gettext-base qrencode util-linux \
    || die "Не удалось установить зависимости"

curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    || die "Не удалось получить ключ nginx.org"

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/$ID $VERSION_CODENAME nginx" \
    | tee /etc/apt/sources.list.d/nginx.list >/dev/null

echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | tee /etc/apt/preferences.d/99nginx >/dev/null

apt-get update
apt-get install -y nginx || die "Не удалось установить nginx"
systemctl enable --now nginx
systemctl enable --now cron

# ==========================================
# Проверка DNS
# ==========================================
LOCAL_IPS=$(hostname -I)
DNS_IPS=$(dig +short "$DOMAIN" | grep -E '^[0-9]+\.')
MATCH=false
for ip in $DNS_IPS; do [[ " $LOCAL_IPS " == *" $ip "* ]] && MATCH=true; done

if [ "$MATCH" != true ]; then
    # VPS за NAT: сравним с внешним адресом
    EXT_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
    for ip in $DNS_IPS; do [[ -n "$EXT_IP" && "$ip" == "$EXT_IP" ]] && MATCH=true; done
fi

if [ "$MATCH" != true ]; then
    echo -e "${RED}❌ Внимание: A-запись $DOMAIN (${DNS_IPS:-нет}) не совпадает с IP сервера ($LOCAL_IPS).${NC}"
    echo -e "${YEL}Укажите в DNS одну A-запись для вашего домена — IP этого сервера.${NC}"
    read -r -p "Продолжить на ваш страх и риск? (y/N): " choice
    [[ "$choice" =~ ^[Yy]$ ]] || die "Выполнение скрипта прервано."
fi

# ==========================================
# Вопросы
# ==========================================
ask AX_TG "Устанавливать Web Proxy для Telegram? (y/n, по умолчанию y):" y
[[ "$AX_TG" =~ ^[Yy]$ ]] && INSTALL_MTP=true || INSTALL_MTP=false

if [ -z "$AX_FP" ]; then
    echo -e "\n${YEL}Выберите TLS fingerprint для маскировки трафика:${NC}"
    echo "1) chrome    3) safari   5) android   7) 360"
    echo "2) firefox   4) ios      6) edge      8) qq"
    read -r -p "Введите номер [1-8] (по умолчанию 2 - firefox): " AX_FP
fi
case $AX_FP in
    1) fpBro="chrome" ;;   3) fpBro="safari" ;;  5) fpBro="android" ;; 7) fpBro="360" ;;
    2) fpBro="firefox" ;;  4) fpBro="ios" ;;     6) fpBro="edge" ;;    8) fpBro="qq" ;;
    chrome|firefox|safari|ios|android|edge|360|qq) fpBro=$AX_FP ;;
    *) fpBro="firefox" ;;
esac

ask AX_USER "Имя первого пользователя (латиница, цифры, _ -; по умолчанию main):" main
[[ "$AX_USER" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || die "Недопустимое имя пользователя: $AX_USER"

WARP_MODE=off
if [ "$INIT_MODE" = direct ]; then
    if [ -z "$AX_WARP" ]; then
        echo -e "\n${BOLD}${YEL}Cloudflare WARP${NC}"
        echo "  Часть трафика сервер сможет выпускать не напрямую, а через сеть Cloudflare."
        echo "  Это касается только того, что дошло до сервера. Что клиент отправит на сервер, решает его маршрутизация."
        echo -e "  ${CYAN}n${NC}   не нужен"
        echo -e "  ${CYAN}y${NC}   включить, нужные сайты вы добавите сами: ${DIM}autoxray warp add сайт.com${NC}"
        echo -e "  ${CYAN}ru${NC}  включить и пускать через WARP российские сайты, которые дошли до сервера"
        echo -e "      ${DIM}Клиенты с маршрутизацией (подписка) российские сайты на сервер не шлют, они открываются напрямую.${NC}"
        echo -e "      ${DIM}Чтобы такой клиент слал их на сервер: autoxray user set имя --ru server${NC}"
        echo -e "      ${DIM}Клиенты без маршрутизации (ссылка vless:// в роутере) отправляют на сервер всё, что вы им настроили.${NC}"
    fi
    ask AX_WARP "Ваш выбор [n]:" n
    case $AX_WARP in y|Y) WARP_MODE=on ;; ru|RU) WARP_MODE=ru ;; esac
fi

WARP_DEPTH=quick
WARP_NIGHTLY=on
if [ "$WARP_MODE" != off ]; then
    if [ -z "$AX_WARP_SCAN" ]; then
        echo -e "\n${BOLD}${YEL}Поиск самого быстрого адреса WARP${NC}"
        echo "  У Cloudflare тысячи адресов WARP, от выбранного зависит задержка. Скорость меряется через туннель на российских сайтах (yandex.ru, vk.ru, rutube.ru)."
        echo -e "  ${CYAN}1${NC}  быстро: по одному адресу из каждого диапазона, около 15 адресов, несколько секунд"
        echo -e "  ${CYAN}2${NC}  подробно: по 20 адресов из диапазона, около 280, 1-3 минуты"
        echo -e "  ${CYAN}3${NC}  все адреса диапазонов, около 3500, может занять десятки минут"
        echo "  После замера скорости три самых быстрых проверяются на стабильность (серия запросов с паузой), это ещё 2-3 минуты."
    fi
    ask AX_WARP_SCAN "Ваш выбор [1]:" 1
    case $AX_WARP_SCAN in 2|more) WARP_DEPTH="more" ;; 3|all) WARP_DEPTH="all" ;; esac
    if [ -z "$AX_WARP_NIGHT" ]; then
        echo -e "\n  Каждую ночь можно перепроверять 15 лучших адресов. Если все медленнее 300 мс, пересканируется весь выбранный набор,"
        echo "  и запомнится новый лучший адрес (Xray при этом перезапускается, только если адрес заметно лучше текущего)."
    fi
    ask AX_WARP_NIGHT "Включить ночную проверку? (Y/n) [Y]:" Y
    [[ "$AX_WARP_NIGHT" =~ ^[Nn]$ ]] && WARP_NIGHTLY=off
fi

# ==========================================
# Ядро: BBR, лимиты
# ==========================================
cat <<EOF > /etc/sysctl.d/999-autoXRAY.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
sysctl --system >/dev/null 2>&1
echo -e "${GRN}BBR, TCP буферы и MTU Probing активированы${NC}"

cat <<EOF > /etc/security/limits.d/99-autoXRAY.conf
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
EOF
ulimit -n 65535
echo -e "${GRN}Лимиты применены. Текущий ulimit -n: $(ulimit -n) ${NC}"

# ==========================================
# CLI autoxray, шаблоны, сайт-маскировка
# ==========================================
echo -e "${YEL}Устанавливаем autoxray...${NC}"
fetch autoxray > /usr/local/bin/autoxray || die "Не удалось получить autoxray"
chmod 755 /usr/local/bin/autoxray
mkdir -p /usr/local/share/autoxray
for t in sub.html nginx.conf report.html gen_page.sh; do
    fetch "templates/$t" > "/usr/local/share/autoxray/$t" || die "Не удалось получить templates/$t"
done
mkdir -p /usr/local/share/autoxray/telegram
for t in install update uninstall; do
    fetch "components/telegram/$t.sh" > "/usr/local/share/autoxray/telegram/$t.sh" || die "Не удалось получить components/telegram/$t.sh"
done

WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH"

AX_STATE=/etc/autoxray/state.json
REUSE=false
if [ -f "$AX_STATE" ]; then
    [ "$(jq -r .domain "$AX_STATE")" = "$DOMAIN" ] \
        || die "Уже установлено для домена $(jq -r .domain "$AX_STATE"). Для другого домена сначала сохраните и удалите $AX_STATE (autoxray backup)."
    REUSE=true
    echo -e "${GRN}Найдена прежняя установка: пользователи и пути сохраняются.${NC}"
    AUTH_PATH=$(jq -r .paths.auth "$AX_STATE")
    path_xhttp=$(jq -r .paths.xhttp "$AX_STATE")
    AX_USER=$(jq -r '.users[0].name' "$AX_STATE")
elif [ "$INIT_MODE" = direct ] && [ -f /usr/local/etc/xray/config.json ] \
        && jq -e '.inbounds[]? | select(.tag == "vsRAWtlsVISION")' /usr/local/etc/xray/config.json >/dev/null 2>&1; then
    echo -e "${YEL}Найдена установка autoXRAY 2.${NC}"
    ask AX_MIGRATE "Перенести её (UUID, ключи, ссылку подписки) в autoXRAY 3? (y/n, по умолчанию y):" y
    if [[ "$AX_MIGRATE" =~ ^[Yy]$ ]]; then
        autoxray migrate "$AX_USER" || die "Перенос не удался"
        REUSE=true
        [ "$(jq -r .domain "$AX_STATE")" = "$DOMAIN" ] || die "Домен в старой установке ($(jq -r .domain "$AX_STATE")) отличается от $DOMAIN."
        AUTH_PATH=$(jq -r .paths.auth "$AX_STATE")
        path_xhttp=$(jq -r .paths.xhttp "$AX_STATE")
    fi
fi
if [ "$REUSE" != true ]; then
    AUTH_PATHS=(
        "/api/v1/authenticate" "/api/auth/login" "/auth/session" "/v2/login"
        "/api/v1/session" "/gateway/auth" "/sso/authenticate" "/api/v2/token"
    )
    AUTH_PATH=${AUTH_PATHS[$RANDOM % ${#AUTH_PATHS[@]}]}
    path_xhttp=$(openssl rand -base64 15 | tr -dc 'a-z0-9' | head -c 6)
fi
[ "$(jq -r '.mode // "direct"' "$AX_STATE" 2>/dev/null)" = bridge ] && INIT_MODE=bridge

bash <(fetch templates/gen_page.sh) "$WEB_PATH" "$AUTH_PATH" || echo -e "${YEL}Сайт-маскировка не сгенерирована, используется заглушка.${NC}"
[ -f "$WEB_PATH/index.html" ] || echo "<!DOCTYPE html><html><head><meta charset='utf-8'><title>$DOMAIN</title></head><body><h1>Server Ready</h1></body></html>" > "$WEB_PATH/index.html"

# ==========================================
# Xray
# ==========================================
# установщик скачивается в файл (сбой загрузки не должен выглядеть как успех); без TERM он падает на вызове tput
XRAY_INSTALLER=$(mktemp)
curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$XRAY_INSTALLER" && [ -s "$XRAY_INSTALLER" ] \
    || die "Не удалось скачать установщик Xray (GitHub недоступен?)"
[[ -z "$TERM" || "$TERM" == dumb ]] && export TERM=xterm
bash "$XRAY_INSTALLER" install --version "$XRAY_VERSION" || die "Не удалось установить Xray $XRAY_VERSION"
rm -f "$XRAY_INSTALLER"
command -v xray >/dev/null || die "Xray не найден после установки"

# ==========================================
# ACME.SH (сертификат)
# ==========================================
CONFIG_PATH="/etc/nginx/conf.d/default.conf"
mkdir -p /var/www/html

cat <<EOF > "$CONFIG_PATH"
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
systemctl reload nginx

mkdir -p /var/lib/xray/cert/
ACME_BIN="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME_BIN" ]; then
    echo -e "${YEL}Установка acme.sh...${NC}"
    curl -fsSL --connect-timeout 10 https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s -- --install-online -m "mail@$DOMAIN"
    if [ ! -f "$ACME_BIN" ]; then
        echo -e "${YEL}Попытка через get.acme.sh...${NC}"
        curl -fsSL --connect-timeout 10 https://get.acme.sh | sh -s email="mail@$DOMAIN"
    fi
fi
[ -f "$ACME_BIN" ] || die "Не удалось установить acme.sh!"

RET=0
if ! "$ACME_BIN" --list | grep -q "$DOMAIN"; then
    "$ACME_BIN" --register-account -m "mail@$DOMAIN" --server zerossl
    echo -e "\n${YEL}Выпуск сертификата (сначала ZeroSSL, затем Let's Encrypt)...${NC}"
    "$ACME_BIN" --issue -d "$DOMAIN" -w /var/www/html --server zerossl --keylength ec-256
    RET=$?
    if [ $RET -ne 0 ]; then
        echo -e "${YEL}ZeroSSL не ответил, пробуем через Let's Encrypt...${NC}"
        "$ACME_BIN" --issue -d "$DOMAIN" -w /var/www/html --server letsencrypt --keylength ec-256
        RET=$?
    fi
else
    echo -e "${GRN}Сертификат для $DOMAIN уже существует в acme.sh.${NC}"
fi
[ $RET -eq 0 ] || die "Не удалось выпустить сертификат через acme.sh"

# Закрытый ключ читает только root и группа, под которой работает xray (раньше было 644 для всех)
XRAY_USER=$(systemctl show xray -p User --value 2>/dev/null); XRAY_USER=${XRAY_USER:-nobody}
XRAY_GROUP=$(id -gn "$XRAY_USER" 2>/dev/null)
if [ -n "$XRAY_GROUP" ]; then
    CERT_FIX="chown root:$XRAY_GROUP /var/lib/xray/cert/privkey.pem /var/lib/xray/cert/fullchain.pem; chmod 640 /var/lib/xray/cert/privkey.pem; chmod 644 /var/lib/xray/cert/fullchain.pem"
else
    CERT_FIX="chmod 644 /var/lib/xray/cert/privkey.pem /var/lib/xray/cert/fullchain.pem"
fi

"$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file /var/lib/xray/cert/fullchain.pem \
    --key-file /var/lib/xray/cert/privkey.pem \
    --reloadcmd "$CERT_FIX; systemctl reload nginx; systemctl restart xray" \
    || die "acme.sh не смог установить сертификат"
bash -c "$CERT_FIX"

echo -e "\n${GRN}✅ Сертификат настроен, acme.sh обновляет его через cron${NC}\n"

# ==========================================
# Состояние autoxray (первый пользователь, пути, ключи)
# ==========================================
if [ "$REUSE" != true ]; then
    autoxray init --domain "$DOMAIN" --fp "$fpBro" --xhttp-path "$path_xhttp" --auth-path "$AUTH_PATH" \
        --web "$WEB_PATH" --user "$AX_USER" --xray-version "$XRAY_VERSION" --mode "$INIT_MODE" "${INIT_NODES[@]}" \
        || die "autoxray init не выполнен"
fi

# Переменные для web-proxy.sh (берёт их из окружения)
export DOMAIN WEB_PATH
socksUser=$(jq -r .socks.user /etc/autoxray/state.json)
socksPasw=$(jq -r .socks.pass /etc/autoxray/state.json)
export socksUser socksPasw

# ==========================================
# Telegram Web Proxy
# ==========================================
if [ "$INSTALL_MTP" = true ]; then
    echo -e "\n\n${GRN}Устанавливаем Telegram Web Proxy ${NC}"
    # shellcheck disable=SC1090
    source <(fetch components/telegram/install.sh)
    [ -n "$MTProto" ] && autoxray telegram set "$MTProto"   # заодно пересоберёт nginx.conf и подписки
else
    echo -e "\n\n${YEL}Установка Telegram Web Proxy пропущена.${NC}"
fi

# ==========================================
# WARP, конфиг Xray, подписки, учёт трафика
# ==========================================
if [ "$WARP_MODE" != off ]; then
    autoxray warp depth "$WARP_DEPTH"
    autoxray warp nightly "$WARP_NIGHTLY"
fi
case $WARP_MODE in
    on) autoxray warp on || echo -e "${YEL}WARP не подключён — повторите позже: autoxray warp on${NC}" ;;
    ru) autoxray warp ru on || echo -e "${YEL}WARP не подключён — повторите позже: autoxray warp ru on${NC}" ;;
esac

autoxray render || die "Не удалось применить конфигурацию Xray (autoxray render)"

autoxray setup-cron

# ==========================================
# Telegram-бот администратора (по желанию)
# ==========================================
if [ -n "$AX_BOT_TOKEN" ]; then
    autoxray bot setup --token "$AX_BOT_TOKEN" ${AX_BOT_ADMIN:+--admin "$AX_BOT_ADMIN"} || echo -e "${YEL}Бот не настроен, повторите: autoxray bot setup${NC}"
elif [ -t 0 ] && [ -z "$AX_NO_BOT" ]; then
    read -r -p "$(echo -e "\n${YEL}Настроить Telegram-бота для управления сервером сейчас? (y/N):${NC} ")" want_bot
    if [[ "$want_bot" =~ ^[Yy]$ ]]; then autoxray bot setup || echo -e "${YEL}Бот не настроен, повторите: autoxray bot setup${NC}"; fi
fi

# ==========================================
# Итог
# ==========================================
echo -e "\n${BOLD}${MAG}🎉 Установка завершена${NC}"
autoxray status

echo -e "\n${BOLD}${YEL}Первый пользователь «$AX_USER»${NC}"
autoxray user link "$AX_USER"

echo -e "${BOLD}${MAG}▌📱 Куда вставить подписку${NC}"
echo -e "  iOS / macOS ${DIM}—${NC} Happ, v2rayTun"
echo -e "  Android     ${DIM}—${NC} Happ, v2rayTun, v2rayNG"
echo -e "  Windows     ${DIM}—${NC} Happ, v2rayN, winLoadXRAY"
echo -e "  ${DIM}Внутри клиента открыт socks5 на 10808 и 2080, http на 10809.${NC}"

echo -e "\n${BOLD}${MAG}▌🧰 Управление${NC}  ${CYAN}autoxray${NC} ${DIM}(меню)${NC}"
echo -e "  ${CYAN}autoxray user add <имя> --limit 50 --days 30${NC}   ${DIM}новый пользователь${NC}"
echo -e "  ${CYAN}autoxray stats${NC}                                 ${DIM}трафик${NC}"
echo -e "  ${CYAN}autoxray doctor${NC}                                ${DIM}диагностика${NC}"
echo -e "  ${CYAN}autoxray bot setup${NC}                             ${DIM}Telegram-бот для управления${NC}"
echo -e "  ${CYAN}autoxray firewall${NC}                              ${DIM}файрвол (по желанию)${NC}"
echo -e "\n${DIM}Документация и релизы: https://github.com/cergo666/autoXRAY${NC}\n"
