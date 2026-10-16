#!/usr/bin/env bash
# Проверка согласованности версий: VERSION, autoxray, install.sh и верхний релиз CHANGELOG.
set -euo pipefail
cd "$(dirname "$0")/.."
v=$(tr -d '[:space:]' < VERSION)
a=$(sed -n 's/^AX_VERSION="\(.*\)"/\1/p' autoxray)
i=$(sed -n 's/^AX_RELEASE="\(.*\)"/\1/p' install.sh)
c=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n1)
ok=1
for pair in "autoxray:$a" "install.sh:$i" "CHANGELOG.md:$c"; do
  [ "${pair#*:}" = "$v" ] || { echo "✘ ${pair%%:*}: '${pair#*:}' != VERSION '$v'"; ok=0; }
done
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✘ VERSION '$v' не SemVer"; ok=0; }
[ "$ok" = 1 ] && echo "✔ версия $v согласована" || exit 1
