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

rm -f "$OUT" /tmp/fake-telegram-curl /tmp/telegram-check.out
finish
