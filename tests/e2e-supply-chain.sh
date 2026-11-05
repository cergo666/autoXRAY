#!/bin/bash
# Проверка загрузчика внешних артефактов: точный SHA-256 принимается,
# подменённый файл отклоняется до копирования/распаковки.
source "$(dirname "$0")/lib.sh"
# shellcheck source=components/telegram/artifacts.sh
source /opt/autoxray/components/telegram/artifacts.sh

step "Подготовка управляемого curl"
cat > /tmp/fake-telegram-curl <<'CURL'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
printf '%s' "${AX_TEST_CURL_PAYLOAD:-verified payload}" > "$out"
CURL
chmod 755 /tmp/fake-telegram-curl
OUT=$(mktemp)
expected=$(printf 'verified payload' | sha256sum | cut -d' ' -f1)

step "Артефакт с ожидаемым digest принимается"
AX_TELEGRAM_CURL=/tmp/fake-telegram-curl telegram_fetch_verified https://example.invalid/artifact "$expected" "$OUT" \
    && [ "$(cat "$OUT")" = 'verified payload' ] \
    && pass "совпавший SHA-256 принят" || fail "валидный SHA-256 отклонён"

step "Изменённый артефакт отклоняется до выдачи файла"
rm -f "$OUT"
if AX_TEST_CURL_PAYLOAD='tampered payload' AX_TELEGRAM_CURL=/tmp/fake-telegram-curl \
    telegram_fetch_verified https://example.invalid/artifact "$expected" "$OUT" >/tmp/telegram-check.out 2>&1; then
    fail "подменённый артефакт принят"
else
    [ ! -e "$OUT" ] && grep -q 'SHA-256 стороннего артефакта не совпал' /tmp/telegram-check.out \
        && pass "подмена остановлена до копирования артефакта" || fail "ошибка хеша не обработана безопасно"
fi

step "Откат Telegram при отказе новой версии"
mkdir -p /tmp/ax-tg-mock
cat > /tmp/ax-tg-mock/systemctl <<'MOCK'
#!/bin/bash
case $1 in
    stop) exit 0 ;;
    start|is-active) grep -q '^old$' /usr/local/bin/ax-test-telegram ;;
esac
MOCK
chmod +x /tmp/ax-tg-mock/systemctl
printf 'old\n' > /usr/local/bin/ax-test-telegram
printf 'new\n' > /tmp/ax-tg-mock/new
# shellcheck disable=SC1090
source <(sed -n '/^replace_service() {/,/^}/p' /opt/autoxray/components/telegram/update.sh)
# shellcheck disable=SC2034
RED=''
# shellcheck disable=SC2034
NC=''
if PATH="/tmp/ax-tg-mock:$PATH" replace_service ax-test-telegram /tmp/ax-tg-mock/new >/tmp/ax-tg-mock/out 2>&1; then
    fail "неработающая версия Telegram принята"
elif [ "$(cat /usr/local/bin/ax-test-telegram)" = old ]; then
    pass "после отказа запуска возвращён прежний бинарник"
else
    fail "прежний бинарник не восстановлен"
fi
rm -f /usr/local/bin/ax-test-telegram /usr/local/bin/.ax-test-telegram.autoxray-backup
rm -rf /tmp/ax-tg-mock
rm -f "$OUT" /tmp/fake-telegram-curl /tmp/telegram-check.out
finish
