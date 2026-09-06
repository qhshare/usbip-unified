#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v flutter >/dev/null 2>&1 || { echo "错误：未找到 Flutter SDK。" >&2; exit 1; }

platform="${1:-linux}"
case "$platform" in
  linux)
    flutter build linux --release
    mkdir -p dist
    tar -C build/linux/x64/release -czf dist/usbip-unified-linux-x64-portable.tar.gz bundle
    echo "Linux 免安装包：dist/usbip-unified-linux-x64-portable.tar.gz"
    ;;
  windows)
    architecture="${2:-x64}"
    case "$architecture" in
      x64|arm64) ;;
      *) echo "用法：$0 windows [x64|arm64]" >&2; exit 2 ;;
    esac
    flutter build windows --release --target-platform "windows-$architecture"
    mkdir -p dist
    command -v zip >/dev/null 2>&1 || { echo "错误：需要 zip 命令。" >&2; exit 1; }
    (cd "build/windows/$architecture/runner/Release" && zip -qr "../../../../../dist/usbip-unified-windows-$architecture-portable.zip" .)
    echo "Windows 免安装包：dist/usbip-unified-windows-$architecture-portable.zip"
    ;;
  *) echo "用法：$0 linux|windows" >&2; exit 2 ;;
esac
