#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
command -v flutter >/dev/null 2>&1 || {
  echo "错误：未找到 Flutter SDK，请先安装 Flutter 并加入 PATH。" >&2
  exit 1
}
if [[ ! -d linux ]]; then
  ./tool/bootstrap.sh
fi
exec flutter run -d linux "$@"
