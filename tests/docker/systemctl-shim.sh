#!/bin/bash
# Подмена systemctl для контейнера: xray и nginx — обычные процессы, остальные службы игнорируются.
XRAY_PID=/run/xray-server.pid

xray_stop()  { [ -f $XRAY_PID ] && kill "$(cat $XRAY_PID)" 2>/dev/null; rm -f $XRAY_PID; sleep 0.3; }
xray_start() {
    if [ "${AX_XRAY_USER:-root}" = root ]; then
        nohup setsid xray run -c /usr/local/etc/xray/config.json >>/var/log/xray/server.out 2>&1 9>&- &
    else
        nohup setsid runuser -u "$AX_XRAY_USER" -- xray run -c /usr/local/etc/xray/config.json >>/var/log/xray/server.out 2>&1 9>&- &
    fi
    echo $! > $XRAY_PID
    for _ in $(seq 1 30); do
        if ss -ltn 2>/dev/null | grep -q ':443 '; then rm -f /run/xray-failed; return 0; fi
        sleep 0.2
    done
    : > /run/xray-failed
    echo "shim: xray не поднялся, лог:" >&2; tail -n 20 /var/log/xray/server.out >&2; return 1
}
nginx_running() { [ -f /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; }

cmd=$1; shift
echo "$cmd $*" >> /run/systemctl.log      # журнал вызовов: тесты проверяют, что нужные службы перезапускаются
case $cmd in
    show)
        prop=""; prev=""
        for a in "$@"; do [[ $prev == -p ]] && prop=$a; prev=$a; done
        case $prop in
            User) printf '%s\n' "${AX_XRAY_USER:-root}" ;;
            *) printf '%s\n' root ;;
        esac ;;
    is-failed) svc=${*: -1}; [ "$svc" = xray ] && [ -e /run/xray-failed ] && { echo failed; exit 0; }; echo active ;;
    is-active) svc=${*: -1}; case $svc in xray) [ -f $XRAY_PID ] && kill -0 "$(cat $XRAY_PID)" 2>/dev/null ;; nginx) nginx_running ;; autoxray-bot) [ -f /run/bot.active ] ;; *) false ;; esac ;;
    restart|start|reload|stop)
        for svc in "$@"; do
            case $svc in
                xray) xray_stop; [ "$cmd" = stop ] || xray_start || exit 1 ;;
                nginx) if [ "$cmd" = stop ]; then nginx -s quit 2>/dev/null
                       elif nginx_running; then nginx -s reload; else nginx; fi ;;
            esac
        done ;;
    *) : ;;
esac
exit 0
