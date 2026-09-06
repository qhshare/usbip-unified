#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v flutter >/dev/null 2>&1 || {
  echo "错误：未找到 Flutter SDK。请先安装 Flutter stable。" >&2
  exit 1
}

# Generate only the desktop runners; lib/ and pubspec.yaml are maintained by this project.
flutter create --platforms=linux,windows --project-name usbip_unified .
flutter pub get
echo "Flutter Linux/Windows 工程文件已生成。运行 ./run.sh 或 run-windows.bat。"
