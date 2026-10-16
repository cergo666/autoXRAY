# autoXRAY

Личный VPN-сервер на [Xray](https://github.com/XTLS/Xray-core) одной командой: маскировка под собственный сайт (selfsteal), несколько пользователей с лимитами, Hysteria2, Telegram Web Proxy, Cloudflare WARP и мост RU → EU. Без панели и базы данных — один CLI `autoxray` и один файл состояния.

> Проект основан на [autoXRAY](https://github.com/xVRVx/autoXRAY) автора xVRVx и развивается как самостоятельная версия.

## Возможности

- **Протоколы на одном порту 443:** VLESS RAW + Vision, VLESS XHTTP (stream-up), Hysteria2 (UDP), Telegram Web Proxy. Всё за TLS-сертификатом вашего домена, остальной трафик получает правдоподобный сайт-маскировку.
- **Несколько пользователей:** у каждого свои ключи и личная страница подписки со ссылками, QR и остатком трафика. Отзыв доступа не трогает остальных.
- **Лимиты:** трафик (ГБ), срок действия, ежемесячный сброс. Клиенты Happ и v2rayTun показывают остаток сами.
- **Готовая подписка с маршрутизацией:** российские сайты идут напрямую, реклама блокируется.
- **WARP:** профиль Cloudflare регистрируется автоматически и работает внутри Xray. Через него можно пускать выбранные домены или российские сайты.
- **Мост RU → EU:** сервер в РФ принимает клиентов и пересылает трафик на один или несколько EU-серверов с автобалансировкой.
- **Сайт-маскировка:** случайный дизайн, тексты и путь формы входа при каждой установке.
- **Управление без правки файлов:** цветное меню и команды, бэкап, обновление, удаление.
- **Диагностика и обслуживание:** `autoxray doctor` проверяет службы, порты, конфиги, DNS, сертификат и диск; гео-данные маршрутизации обновляются сами раз в неделю; файрвол настраивается одной командой.

## Требования

- Чистый VPS с Debian 12/13 (подойдёт Ubuntu), root-доступ.
- Домен или поддомен с **одной** A-записью на IP сервера (DNS должен успеть обновиться).
- Открытые порты 80/tcp (выпуск сертификата) и 443/tcp+udp.
- Подсети некоторых хостингов заблокированы провайдерами РФ — выбирайте провайдера, до которого доходит SSH без VPN.

## Установка

```bash
bash -c "$(curl -L https://github.com/cergo666/autoXRAY/releases/latest/download/install.sh)" -- вашдомен.com
```

Установщик задаст несколько вопросов (Telegram Web Proxy, TLS fingerprint, имя первого пользователя, WARP), выпустит сертификат, настроит nginx и Xray и выведет ссылки. Конкретную версию можно взять из [Releases](https://github.com/cergo666/autoXRAY/releases): `.../releases/download/v3.0.0/install.sh`.

Без вопросов (для автоматизации):

```bash
AX_TG=y AX_FP=2 AX_USER=anna AX_WARP=n bash install.sh вашдомен.com
```

| Переменная | Значение |
|---|---|
| `AX_TG` | `y` / `n` — Telegram Web Proxy |
| `AX_FP` | TLS fingerprint: `1` chrome, `2` firefox, `3` safari, `4` ios, `5` android, `6` edge, `7` 360, `8` qq |
| `AX_USER` | имя первого пользователя |
| `AX_WARP` | `n` — нет, `y` — WARP со своим списком, `ru` — плюс российские сайты через WARP |

Повторный запуск с тем же доменом сохраняет пользователей и ключи.

### Клиентские приложения

Скопируйте ссылку подписки (или нажмите «Добавить в Happ» на личной странице) в приложение:

| Платформа | Приложения |
|---|---|
| iOS / macOS | [Happ](https://www.happ.su/main/ru), [v2rayTun](https://v2raytun.com/) |
| Android | [Happ](https://www.happ.su/main/ru), [v2rayTun](https://v2raytun.com/) |
| Windows | [Happ](https://www.happ.su/main/ru), [v2rayN](https://github.com/2dust/v2rayN/releases/) |
| Linux | [Happ](https://www.happ.su/main/ru), [v2rayN](https://github.com/2dust/v2rayN/releases/) |

Подписка содержит готовый клиентский конфиг с маршрутизацией — встроенную маршрутизацию приложения выключите. Отдельные `vless://` и `hy2://` ссылки подходят для приложений без поддержки клиентского конфига; для маршрутизации в них настройте правила самостоятельно.

## Управление

Команда `autoxray` без аргументов открывает меню.

```bash
autoxray user add anna --limit 50 --days 30 --reset monthly   # 50 ГБ, 30 дней, сброс раз в месяц
autoxray user list                                            # статус, трафик, срок
autoxray user link anna                                       # страница, подписка, ссылки
autoxray user qr anna [sub|xhttp|vision|hy2]                  # QR в терминале
autoxray user set anna --limit 100 --reset-traffic            # изменить лимит, сбросить счётчик
autoxray user set anna --disable                              # временно отключить (--enable вернуть)
autoxray user rotate anna                                     # новые ключи и новая ссылка
autoxray user del anna                                        # удалить
autoxray stats                                                # трафик по пользователям
autoxray status                                               # службы, сертификат, WARP
autoxray fingerprint chrome                                   # сменить TLS fingerprint
autoxray doctor                                               # диагностика: что не так и как исправить
autoxray firewall                                             # ufw: SSH, 80, 443/tcp+udp (с подтверждением)
autoxray geo-update                                           # обновить geoip/geosite сейчас
```

`autoxray user list --plain` и `autoxray user link <имя> --plain` печатают данные без оформления (таблица пользователей; пары `название|ссылка`) — для скриптов.

Лимиты и сроки проверяются раз в 5 минут. Пользователь, исчерпавший лимит или срок, отключается автоматически; `--reset-traffic` или продление возвращают доступ.

### Личная страница и подписка

Каждому пользователю выдаётся секретный адрес `https://домен/<токен>.html` (приложения, кнопки добавления, QR, отдельные конфиги, остаток трафика) и `https://домен/<токен>.json` (сама подписка). `autoxray user rotate` выпускает новый токен — старая ссылка перестаёт работать.

### WARP

```bash
autoxray warp on                  # зарегистрировать профиль Cloudflare и включить
autoxray warp ru on               # российские сайты через WARP (обновите подписку в клиентах)
autoxray warp ru off              # вернуть прямой выход для российских сайтов
autoxray warp add chatgpt.com     # свой домен через WARP (warp del — убрать)
autoxray warp check               # проверка: в ответе должно быть warp=on
autoxray warp off
```

По умолчанию клиент отправляет российские сайты напрямую с устройства, и сервер их не видит. Режим `warp ru on` меняет подписку: российский трафик уходит на сервер и дальше через WARP. Принимает ли конкретный российский сервис адреса Cloudflare, зависит от самого сервиса — проверьте на нужных вам сайтах.

### Telegram Web Proxy

Устанавливается по желанию вместе с сервером и работает на том же 443 порту. Ссылка добавления выводится в конце установки и лежит на личных страницах.

```bash
autoxray telegram update     # обновить TeleMT и tproxy-server
autoxray telegram remove     # удалить Web Proxy
```

## Мост RU → EU

Если подсеть вашего EU-хостинга блокируется (особенно в мобильных сетях), поставьте сервер-мост на VPS в РФ. Клиенты подключаются к RU-серверу, а он пересылает трафик на EU.

1. На EU-сервере выполните обычную установку. В `autoxray user link <имя>` возьмите ссылку **VLESS XHTTP TLS stream-up** (для моста). Для нескольких узлов создайте по пользователю на каждом EU-сервере.
2. На RU-сервере передайте ссылки после домена:

```bash
bash -c "$(curl -L https://github.com/cergo666/autoXRAY/releases/latest/download/install.sh)" -- мост.вашдомен.com "vless://узел1" "vless://узел2"
```

Цепочка: клиент → RU-сервер → EU-сервер → сайт. При нескольких узлах появляется профиль «Автобалансир» и отдельные профили на каждый узел. Узлами управляют команды:

```bash
autoxray node list
autoxray node add "vless://..."
autoxray node del <имя|id>
```

Поддерживаются узлы с `security=tls` или `none`; REALITY-ссылки не принимаются. Режимы моста и WARP исключают друг друга — российский трафик моста и так идёт напрямую.

## Обновление и перенос

```bash
autoxray self-update            # до последнего релиза (или: autoxray self-update v3.1.0)
autoxray update-core            # только ядро Xray
autoxray backup                 # архив со всеми ключами, сертификатами и конфигами
autoxray restore файл.tar.gz
```

Перед обновлением прочитайте заметки к релизу — там указано, нужно ли пользователям обновлять подписки.

**Переход с autoXRAY 2.** Запустите установщик с тем же доменом на прежнем сервере: он найдёт старую установку и предложит перенести её. UUID, пароль Hysteria2, ключи и адрес ссылки подписки сохраняются, клиентам ничего менять не нужно. Прежний `config.json` сохраняется в `/etc/autoxray/config.v2.json.bak`.

## Удаление

```bash
autoxray uninstall
```

Удаляет Xray, nginx, acme.sh, Web Proxy, сайт и все данные (после подтверждения).

## Где что лежит

| Путь | Назначение |
|---|---|
| `/etc/autoxray/state.json` | единственный источник правды: пользователи, пути, WARP, узлы моста |
| `/etc/autoxray/traffic.json` | накопленные счётчики трафика |
| `/usr/local/etc/xray/config.json` | конфиг Xray (**генерируется**, правки перезаписываются) |
| `/etc/nginx/conf.d/default.conf` | конфиг nginx (генерируется) |
| `/var/www/<домен>/` | сайт-маскировка и файлы подписок |
| `/var/lib/xray/cert/` | сертификат (обновляется через acme.sh) |

Изменить что-то вручную можно только через CLI или `state.json` с последующим `autoxray render`. Конфиг перед применением проверяется `xray run -test`; при ошибке остаётся прежний.

## Рекомендации по безопасности

- Смените порт SSH и/или оставьте вход только по ключу.
- Файрвол: оставьте открытыми порт SSH, 80/tcp и 443/tcp+udp.
- Не делитесь личными страницами пользователей — адрес и есть секрет.
- Храните бэкапы в безопасном месте: в них приватные ключи.

## Разработка

```bash
tests/run.sh all        # все e2e в Docker: direct, bridge, install, migrate
tests/run.sh direct     # один сценарий
tests/check-version.sh  # согласованность версий
```

Тесты поднимают настоящие Xray и nginx в контейнерах и пропускают трафик клиента через каждый протокол, проверяют лимиты, WARP-конфиг, мост из двух серверов, установщик и миграцию. Внешние сервисы (apt, ACME, Cloudflare API) заменены заглушками.

### Релизы

Версии подчиняются [SemVer](https://semver.org/lang/ru/), изменения описаны в [CHANGELOG.md](CHANGELOG.md), релизы — в [Releases](https://github.com/cergo666/autoXRAY/releases). Ветка `main` — разрабатываемая версия; для установки используйте релиз. Состояние до перехода на релизы сохранено тегом `v2-legacy`.

Выпуск:

```bash
tools/bump-version.sh 3.1.0         # VERSION, autoxray, install.sh, заготовка в CHANGELOG
# дополнить CHANGELOG, затем
git commit -am "Release v3.1.0" && git tag -a v3.1.0 -m "v3.1.0" && git push origin main v3.1.0
```

Тег запускает [workflow](.github/workflows/release.yml): проверка версий, тесты, сборка `install.sh`, закреплённого на тег, и публикация релиза с заметками из CHANGELOG.

## Благодарности

- [xVRVx/autoXRAY](https://github.com/xVRVx/autoXRAY) — исходный проект и идея.
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — ядро.
- [ImMALWARE/bash-warp-generator](https://github.com/ImMALWARE/bash-warp-generator) (MIT) — способ регистрации профиля WARP через API Cloudflare.
- [telemt](https://github.com/telemt/telemt) и [tproxy-server](https://github.com/telegramdesktop/tproxy-server) — Telegram Web Proxy.

## Лицензия

GPL-3.0, см. [LICENSE](LICENSE).
