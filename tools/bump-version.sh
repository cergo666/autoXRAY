#!/usr/bin/env bash
# Подготовка релиза:  tools/bump-version.sh 3.1.0
# Меняет VERSION, autoxray, install.sh и добавляет раздел в CHANGELOG. Коммит и тег — вручную (см. README, «Релизы»).
set -euo pipefail
cd "$(dirname "$0")/.."
new=${1:?usage: $0 X.Y.Z}
[[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "версия вида X.Y.Z"; exit 1; }
echo "$new" > VERSION
sed -i "s/^AX_VERSION=\".*\"/AX_VERSION=\"$new\"/" autoxray
sed -i "s/^AX_RELEASE=\".*\"/AX_RELEASE=\"$new\"/" install.sh
grep -q "^## \[$new\]" CHANGELOG.md || sed -i "0,/^## \[Unreleased\]/s//## [Unreleased]\n\n## [$new] — $(date +%F)/" CHANGELOG.md
tests/check-version.sh
echo "Дальше: допишите CHANGELOG, затем:"
echo "  git commit -am 'Release v$new' && git tag -a v$new -m 'v$new' && git push origin main v$new"
