#!/bin/bash
# Подмена systemctl для контейнера: xray и nginx — обычные процессы, остальные службы игнорируются.
XRAY_PID=/run/xray-server.pid

xray_stop()  { [ -f $XRAY_PID ] && kill "$(cat $XRAY_PID)" 2>/dev/null; rm -f $XRAY_PID; sleep 0.3; }
xray_start() {
    nohup setsid xray run -c /usr/local/etc/xray/config.json >>/var/log/xray/server.out 2>&1 9>&- &
    echo $! > $XRAY_PID
    for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ':443 ' && return 0; sleep 0.2; done
    echo "shim: xray не поднялся, лог:" >&2; tail -n 20 /var/log/xray/server.out >&2; return 1
}
nginx_running() { [ -f /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; }

cmd=$1; shift
case $cmd in
    show) echo root ;;
    is-active) svc=${*: -1}; case $svc in xray) [ -f $XRAY_PID ] && kill -0 "$(cat $XRAY_PID)" 2>/dev/null ;; nginx) nginx_running ;; *) false ;; esac ;;
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
