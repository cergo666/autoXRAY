#!/usr/bin/env bash
# Запуск e2e в Docker:  tests/run.sh [direct|bridge|install|all]   (по умолчанию all)
# Наборы независимы (каждый в своём контейнере), поэтому `all` запускает их параллельно и печатает журналы по очереди.
# AX_SERIAL=1 — по одному, с выводом в реальном времени.
set -euo pipefail
cd "$(dirname "$0")/.."
IMG=autoxray-test:local
docker build -q -t "$IMG" tests/docker >/dev/null

run() {
  docker run --rm --cap-add NET_ADMIN -v "$PWD":/opt/autoxray:ro "$IMG" bash -c "/opt/autoxray/tests/$1"
}

suite() { # имя -> запуск набора
  case $1 in
    direct)  run e2e-direct.sh ;;
    bridge)  tests/e2e-bridge-host.sh ;;
    fresh)   run "e2e-install.sh fresh" ;;
    migrate) run "e2e-install.sh migrate" ;;
    verify)  run "e2e-install.sh verify" ;;
  esac
}

case "${1:-all}" in
  direct)  suites=(direct) ;;
  bridge)  suites=(bridge) ;;
  install) suites=(fresh migrate verify) ;;
  all)     suites=(direct bridge fresh migrate verify) ;;
  *) echo "usage: $0 [direct|bridge|install|all]"; exit 2 ;;
esac

if [[ ${AX_SERIAL:-0} == 1 || ${#suites[@]} -eq 1 ]]; then
  for s in "${suites[@]}"; do suite "$s"; done
  exit 0
fi

logs=$(mktemp -d); trap 'rm -rf "$logs"' EXIT
declare -A rc=() took=()
for s in "${suites[@]}"; do
  ( t=$SECONDS; r=0; suite "$s" >"$logs/$s.log" 2>&1 || r=$?; echo "$r $((SECONDS - t))" >"$logs/$s.rc" ) &
done
wait
bad=0
for s in "${suites[@]}"; do
  read -r rc[$s] took[$s] <"$logs/$s.rc"
  echo -e "\n\033[1;35m════ $s (${took[$s]} с) ════\033[0m"
  cat "$logs/$s.log"
  [[ ${rc[$s]} -eq 0 ]] || bad=1
done
echo
for s in "${suites[@]}"; do
  [[ ${rc[$s]} -eq 0 ]] && echo -e "  \033[1;32m✔\033[0m $s (${took[$s]} с)" || echo -e "  \033[1;31m✘\033[0m $s (${took[$s]} с)"
done
exit $bad
