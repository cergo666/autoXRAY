#!/usr/bin/env bash
# Запуск e2e в Docker:  tests/run.sh [direct|bridge|install|all]   (по умолчанию all)
set -euo pipefail
cd "$(dirname "$0")/.."
IMG=autoxray-test:local
docker build -q -t "$IMG" tests/docker >/dev/null

run() {
  docker run --rm --cap-add NET_ADMIN -v "$PWD":/opt/autoxray:ro "$IMG" bash -c "/opt/autoxray/tests/$1"
}

case "${1:-all}" in
  direct)  run e2e-direct.sh ;;
  bridge)  tests/e2e-bridge-host.sh ;;
  install) run "e2e-install.sh fresh" && run "e2e-install.sh migrate" ;;
  all)     run e2e-direct.sh && tests/e2e-bridge-host.sh && run "e2e-install.sh fresh" && run "e2e-install.sh migrate" ;;
  *) echo "usage: $0 [direct|bridge|install|all]"; exit 2 ;;
esac
