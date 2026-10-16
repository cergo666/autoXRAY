#!/usr/bin/env bash
# Оркестратор e2e моста: две контейнера в общей сети docker (EU и RU), общий тестовый CA.
set -euo pipefail
cd "$(dirname "$0")/.."
IMG=autoxray-test:local
ID=$$
NET=axnet-$ID
CA=$(mktemp -d); chmod 777 "$CA"
cleanup() { docker rm -f "ax-eu-$ID" "ax-ru-$ID" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; docker run --rm -v "$CA":/c "$IMG" sh -c "rm -rf /c/* /c/.[!.]*" >/dev/null 2>&1 || true; rm -rf "$CA" 2>/dev/null || true; }
trap cleanup EXIT

docker build -q -t "$IMG" tests/docker >/dev/null
docker network create "$NET" >/dev/null
for r in eu ru; do
  docker run -d --name "ax-$r-$ID" --network "$NET" --network-alias "$r.test" --cap-add NET_ADMIN \
    -v "$PWD":/opt/autoxray:ro -v "$CA":/tmp/ca "$IMG" sleep infinity >/dev/null
done

docker exec "ax-eu-$ID" bash /opt/autoxray/tests/e2e-bridge.sh eu
EU_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "ax-eu-$ID")
docker exec -e EU_IP="$EU_IP" "ax-ru-$ID" bash /opt/autoxray/tests/e2e-bridge.sh ru
