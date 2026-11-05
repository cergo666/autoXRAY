#!/bin/bash
set -e

# shellcheck source=components/telegram/artifacts.sh
source "$(dirname "${BASH_SOURCE[0]}")/artifacts.sh"

GRN='\033[1;32m'
YEL='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ Запустите скрипт с правами root${NC}"; exit 1; }

echo -e "${GRN}=== Обновление TeleMT и Telegram Web Proxy ===${NC}\n"

# Создаем временные каталоги с гарантированной очисткой при выходе
TMP_DIR=$(mktemp -d)
TMP_SRC=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR" "$TMP_SRC"; }
trap cleanup EXIT

replace_service() {
    local service=$1 candidate=$2 target="/usr/local/bin/$1" backup="/usr/local/bin/.$1.autoxray-backup"
    if [[ -e $target ]]; then
        cp -p "$target" "$backup" || { echo "Не удалось сохранить $target" >&2; return 1; }
    else
        rm -f "$backup" || return 1
    fi
    systemctl stop "$service" 2>/dev/null || true
    if install -m 755 "$candidate" "$target" && systemctl start "$service" && sleep 2 && systemctl is-active --quiet "$service"; then
        rm -f "$backup"
        return 0
    fi
    echo -e "${RED}Ошибка запуска $service, восстанавливаем прежнюю версию${NC}" >&2
    systemctl stop "$service" 2>/dev/null || true
    if [[ -e $backup ]]; then
        if cp -p "$backup" "$target" && systemctl start "$service" && systemctl is-active --quiet "$service"; then
            rm -f "$backup"
        else
            echo "Не удалось восстановить $service; копия: $backup" >&2
        fi
    else
        rm -f "$target"
    fi
    return 1
}

# --- 1. ОБНОВЛЕНИЕ TELEMT ---
echo -e "${GRN}[1/2] Обновление TeleMT...${NC}"
echo "Скачивание TeleMT $TELEMT_VERSION и проверка SHA-256..."
telegram_install_telemt "$TMP_DIR/telemt" || { echo -e "${RED}❌ Проверка/скачивание TeleMT не прошла${NC}"; exit 1; }

replace_service telemt "$TMP_DIR/telemt" || exit 1
echo -e "${YEL}TeleMT обновлен и запущен.${NC}\n"


# --- 2. ОБНОВЛЕНИЕ TPROXY-SERVER ---
echo -e "${GRN}[2/2] Обновление tproxy-server...${NC}"

GO_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
GO_BIN=""

# Проверяем, есть ли уже подходящий системный Go (требуется >= 1.20)
if command -v go &>/dev/null; then
    SYS_GO_VER=$(go version 2>/dev/null | grep -oE 'go1\.[0-9]+' | cut -d. -f2 || true)
    if [ -n "$SYS_GO_VER" ] && [ "$SYS_GO_VER" -ge 20 ] 2>/dev/null; then
        GO_BIN=$(command -v go)
        echo "Используется системный Go: $(go version)"
    fi
fi

# Если системного нет или он старый — скачиваем Go 1.22.6 с зеркалом и валидацией хеша
if [ -z "$GO_BIN" ]; then
    echo "Загрузка Go 1.22.6..."
    GO_TGZ="go1.22.6.linux-${GO_ARCH}.tar.gz"

    case "$GO_ARCH" in
        amd64) GO_SHA256="999805bed7d9039ec3da1a53bfbcafc13e367da52aa823cb60b68ba22d44c616" ;;
        arm64) GO_SHA256="c15fa895341b8eaf7f219fada25c36a610eb042985dc1a912410c1c90098eaf2" ;;
        *) echo -e "${RED}❌ Неподдерживаемая архитектура: $GO_ARCH${NC}"; exit 1 ;;
    esac

    mkdir -p "$TMP_DIR/go"

    for url in "https://go.dev/dl/$GO_TGZ" "https://mirrors.aliyun.com/golang/$GO_TGZ"; do
        if curl -fsSL --retry 2 "$url" -o "$TMP_DIR/go.tgz" && \
           printf '%s  %s\n' "$GO_SHA256" "$TMP_DIR/go.tgz" | sha256sum -c --quiet - && \
           tar -C "$TMP_DIR/go" --strip-components=1 -xzf "$TMP_DIR/go.tgz"; then
            break
        fi
        echo -e "${YEL}Не удалось скачать Go с $url, пробую зеркало...${NC}"
    done
    rm -f "$TMP_DIR/go.tgz"

    [ -x "$TMP_DIR/go"/bin/go ] || { echo -e "${RED}❌ Не удалось развернуть Go тулчейн${NC}"; exit 1; }
    GO_BIN="$TMP_DIR/go/bin/go"
fi

# Скачивание закреплённого commit tproxy-server и проверка SHA-256
echo "Скачивание tproxy-server $TPROXY_COMMIT и проверка SHA-256..."
telegram_extract_tproxy_source "$TMP_SRC" || { echo -e "${RED}❌ Проверка/скачивание исходников tproxy-server не прошла${NC}"; exit 1; }

echo "Компиляция бинарника..."
cd "$TMP_SRC"
CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags="-s -w" -o "$TMP_SRC/tproxy-server.new" ./cmd/tproxy-server \
    || { echo -e "${RED}❌ Ошибка сборки tproxy-server${NC}"; exit 1; }

replace_service tproxy-server "$TMP_SRC/tproxy-server.new" || exit 1
cd /root
echo -e "${YEL}tproxy-server успешно пересобран и запущен.${NC}\n"


# --- 3. ПРОВЕРКА СТАТУСА ---
echo -e "${GRN}=== Проверка статуса сервисов ===${NC}"
sleep 2

telemt_status=$(systemctl is-active telemt 2>/dev/null || true)
tproxy_status=$(systemctl is-active tproxy-server 2>/dev/null || true)

if [ "$telemt_status" = "active" ]; then
    echo -e "TeleMT:        [ ${GRN}ACTIVE / RUNNING${NC} ]"
else
    echo -e "TeleMT:        [ ${RED}FAILED${NC} ] (журнал: journalctl -u telemt -e)"
fi

if [ "$tproxy_status" = "active" ]; then
    echo -e "tproxy-server: [ ${GRN}ACTIVE / RUNNING${NC} ]"
else
    echo -e "tproxy-server: [ ${RED}FAILED${NC} ] (журнал: journalctl -u tproxy-server -e)"
fi

[[ $telemt_status == active && $tproxy_status == active ]] || exit 1
echo -e "\n${GRN}Готово! Все настройки, секреты и файлы сохранены.${NC}"
