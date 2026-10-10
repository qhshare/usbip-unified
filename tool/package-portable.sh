#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"

platform="${1:-linux}"
shift || true
no_pub=0
architecture="x64"
build_name="${BUILD_NAME:-0.1.0}"
project_version="$(awk '/^version:[[:space:]]*/ {print $2; exit}' pubspec.yaml)"
package_version="${project_version#*+}"
build_number="${BUILD_NUMBER:-$package_version}"

if [[ -z "$project_version" || -z "$package_version" || "$package_version" == "$project_version" ]]; then
  echo "错误：无法从 pubspec.yaml 读取带构建号的版本。" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pub)
      no_pub=1
      shift
      ;;
    --pub)
      no_pub=0
      shift
      ;;
    x64|arm64)
      architecture="$1"
      shift
      ;;
    *)
      echo "用法：$0 linux [--no-pub]" >&2
      echo "      $0 windows [x64|arm64] [--no-pub]" >&2
      exit 2
      ;;
  esac
done

if [[ "$platform" == "windows" ]]; then
  case "$(uname -s 2>/dev/null || printf 'unknown')" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
      echo "错误：不能在 Linux/macOS 主机上生成可信的 Windows Flutter 包。" >&2
      echo "Windows 的 Dart 前端和 release Engine 必须在原生 Windows + Visual Studio 工具链上构建。" >&2
      echo "请在 Windows 中执行：flutter clean && flutter pub get && tool\\package-portable.bat x64 --no-pub" >&2
      exit 2
      ;;
  esac
fi

command -v "$flutter_bin" >/dev/null 2>&1 || {
  echo "错误：未找到 Flutter SDK：$flutter_bin" >&2
  exit 1
}

prepare_flutter_dependencies() {
  if [[ "$no_pub" == "1" ]]; then
    if [[ ! -f .dart_tool/package_config.json ]]; then
      echo "错误：--no-pub 需要现有的 .dart_tool/package_config.json。" >&2
      echo "请先在可联网环境执行：flutter pub get" >&2
      exit 1
    fi
    echo "复用现有 Dart 依赖（--no-pub），跳过 flutter pub get；清理生成的构建缓存。"
    rm -rf build .dart_tool/flutter_build
    return
  fi
  "$flutter_bin" clean
  "$flutter_bin" pub get
}

validate_aot_snapshot() {
  local snapshot="$1"
  local expected_architecture="$2"
  local expected_platform="$3"
  local snapshot_text

  test -f "$snapshot" || {
    echo "错误：找不到 AOT 快照：$snapshot" >&2
    exit 1
  }
  snapshot_text="$(strings "$snapshot")"
  if ! grep -Fq 'product no-asan' <<< "$snapshot_text"; then
    echo "错误：AOT 快照不是 product 模式：$snapshot" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_architecture $expected_platform" <<< "$snapshot_text"; then
    echo "错误：AOT 快照目标平台不匹配，期望 $expected_architecture $expected_platform：$snapshot" >&2
    exit 1
  fi
}

case "$platform" in
  linux)
    prepare_flutter_dependencies
    if [[ "$no_pub" == "1" ]]; then
      "$flutter_bin" build linux --release --no-pub
    else
      "$flutter_bin" build linux --release
    fi
    validate_aot_snapshot build/linux/x64/release/bundle/lib/libapp.so x64 linux
    test -f build/linux/x64/release/bundle/usbip_unified || {
      echo "错误：Linux bundle 缺少可执行文件。" >&2
      exit 1
    }
    mkdir -p dist
    archive="dist/usbip-unified-linux-x64-portable-$package_version.tar.gz"
    rm -f "$archive"
    tar -C build/linux/x64/release -czf "$archive" bundle
    echo "Linux 免安装包：$archive"
    ;;
  windows)
    case "$architecture" in
      x64|arm64) ;;
      *) echo "用法：$0 windows [x64|arm64]" >&2; exit 2 ;;
    esac
    prepare_flutter_dependencies
    build_args=(build windows --release)
    if [[ "$architecture" == "arm64" ]]; then
      build_args+=(--target-platform windows-arm64)
    fi
    if [[ "$no_pub" == "1" ]]; then
      "$flutter_bin" "${build_args[@]}" --no-pub --build-name "$build_name" --build-number "$build_number"
    else
      "$flutter_bin" "${build_args[@]}" --build-name "$build_name" --build-number "$build_number"
    fi
    mkdir -p dist
    command -v zip >/dev/null 2>&1 || { echo "错误：需要 zip 命令。" >&2; exit 1; }
    build_dir="build/windows/$architecture/runner/Release"
    snapshot="$build_dir/data/app.so"
    validate_aot_snapshot "$snapshot" "$architecture" windows
    test -f "$build_dir/usbip_unified.exe" || {
      echo "错误：Windows bundle 缺少 PE 可执行文件。" >&2
      exit 1
    }
    test -f "$build_dir/flutter_windows.dll" || {
      echo "错误：Windows bundle 缺少 flutter_windows.dll。" >&2
      exit 1
    }
    script="$build_dir/data/flutter_assets/offline/install-windows-offline.ps1"
    archive="dist/usbip-unified-windows-$architecture-portable-$package_version.zip"
    test -f "$script" || { echo "错误：Windows bundle 中没有离线安装脚本。" >&2; exit 1; }
    if [[ "$architecture" == "x64" ]]; then
      required_client_files=(
        "data/flutter_assets/offline/windows/x64/usbipd-win_5.3.0_x64.msi"
        "data/flutter_assets/offline/windows/x64/VC_redist.x64.exe"
        "data/flutter_assets/offline/windows/x64/USBip-0.9.8.0-x64.exe"
      )
      for relative_path in "${required_client_files[@]}"; do
        test -f "$build_dir/$relative_path" || {
          echo "错误：Windows bundle 缺少客户端资源：$relative_path" >&2
          echo "请确认 pubspec.yaml 声明了官方 USBip-0.9.8.0-x64.exe，并重新执行 Flutter 构建。" >&2
          exit 1
        }
      done
      legacy_payload="$build_dir/data/flutter_assets/offline/windows/x64/client"
      if [[ -d "$legacy_payload" ]]; then
        echo "错误：Windows x64 bundle 不应包含旧的 client/ 固定 payload：$legacy_payload" >&2
        echo "请清理构建目录后重新执行 Flutter 构建。" >&2
        exit 1
      fi
      for legacy_driver in \
        "data/flutter_assets/offline/windows/x64/usbip_vhci.inf" \
        "data/flutter_assets/offline/windows/x64/usbip_vhci.sys" \
        "data/flutter_assets/offline/windows/x64/usbip_vhci.cat"; do
        if [[ -f "$build_dir/$legacy_driver" ]]; then
          echo "错误：Windows x64 bundle 不应包含旧 VHCI 驱动：$legacy_driver" >&2
          echo "请清理构建目录后重新执行 Flutter 构建。" >&2
          exit 1
        fi
      done
      legacy_client_installer="$build_dir/data/flutter_assets/offline/windows/x64/USBip-0.9.7.7-x64.exe"
      if [[ -f "$legacy_client_installer" ]]; then
        echo "错误：Windows x64 bundle 不应包含旧客户端安装器：$legacy_client_installer" >&2
        echo "请确认 pubspec.yaml 使用了显式 x64 asset 清单，并重新执行 Flutter 构建。" >&2
        exit 1
      fi
    fi
    source_hash="$(sha256sum offline/install-windows-offline.ps1 | awk '{print $1}')"
    bundle_hash="$(sha256sum "$script" | awk '{print $1}')"
    if [[ "$source_hash" != "$bundle_hash" ]]; then
      echo "错误：bundle 中的 PowerShell 脚本与源码不一致。" >&2
      echo "源码：$source_hash" >&2
      echo "bundle：$bundle_hash" >&2
      exit 1
    fi
    rm -f "$archive"
    (cd "$build_dir" && zip -qr "../../../../../$archive" .)
    archive_hash="$(unzip -p "$archive" data/flutter_assets/offline/install-windows-offline.ps1 | sha256sum | awk '{print $1}')"
    if [[ "$source_hash" != "$archive_hash" ]]; then
      echo "错误：生成的 ZIP 中的 PowerShell 脚本校验失败。" >&2
      echo "源码：$source_hash" >&2
      echo "ZIP：$archive_hash" >&2
      exit 1
    fi
    if [[ "$architecture" == "x64" ]]; then
      for relative_path in "${required_client_files[@]}"; do
        unzip -p "$archive" "$relative_path" >/dev/null 2>&1 || {
          echo "错误：生成的 ZIP 缺少客户端资源：$relative_path" >&2
          exit 1
        }
      done
    fi
    archive_snapshot_text="$(unzip -p "$archive" data/app.so | strings)"
    if ! grep -Fq 'product no-asan' <<< "$archive_snapshot_text" ||
      ! grep -Fq "$architecture windows" <<< "$archive_snapshot_text"; then
      echo "错误：生成的 ZIP 中的 AOT 快照不是 Windows product 快照。" >&2
      exit 1
    fi
    echo "Windows 免安装包：$archive"
    echo "ZIP 中脚本 SHA256：$archive_hash"
    ;;
  *) echo "用法：$0 linux|windows" >&2; exit 2 ;;
esac
