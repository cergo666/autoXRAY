#!/usr/bin/env bash
# Каждая вызываемая в autoxray функция (cmd_*, menu_*, warp_*, core_*) должна быть определена.
set -euo pipefail
cd "$(dirname "$0")/.."
used=$(grep -oP '(?:^|[\s(;&|!{])\K(cmd|menu|warp|core|user_menu)_[a-z_]+\b(?!=)' autoxray | sort -u)
missing=0
for f in $used; do
  grep -qE "^$f\(\) *\{" autoxray || grep -qE "^ *$f\(\) *\{" autoxray || { echo "✘ не определена функция: $f"; missing=1; }
done
[ "$missing" = 0 ] && echo "✔ все используемые функции определены" || exit 1
