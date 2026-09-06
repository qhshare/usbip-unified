#!/usr/bin/env bash
# Installs the bundled USB/IP user-space packages that match the host
# architecture. Kernel modules are always taken from the running kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH_OVERRIDE=""
DISTRO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture)
      ARCH_OVERRIDE="${2:-}"
      shift 2
      ;;
    --architecture=*)
      ARCH_OVERRIDE="${1#*=}"
      shift
      ;;
    --distribution)
      DISTRO_OVERRIDE="${2:-}"
      shift 2
      ;;
    --distribution=*)
      DISTRO_OVERRIDE="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "用法: install-linux-offline.sh [--architecture amd64|i386|arm64|armhf] [--distribution kali|debian-bookworm]"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 执行此脚本。" >&2
  exit 1
fi
if [[ ! -r /etc/os-release ]] || ! grep -Eiq '^(ID|ID_LIKE)=.*(kali|debian)' /etc/os-release; then
  echo "此离线包仅针对 Kali/Debian 系发行版构建，已拒绝安装。" >&2
  exit 1
fi
if ! command -v dpkg >/dev/null 2>&1; then
  echo "未找到 dpkg；此安装器仅支持 Kali/Debian 系统。" >&2
  exit 1
fi
if [[ ! -d /lib/modules/$(uname -r) ]]; then
  echo "未找到当前内核的模块目录：/lib/modules/$(uname -r)" >&2
  exit 1
fi

# dpkg is authoritative for the package architecture; uname -m is the fallback.
if [[ -n "$ARCH_OVERRIDE" ]]; then
  ARCH="$ARCH_OVERRIDE"
else
  ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
  if [[ -z "$ARCH" ]]; then
    case "$(uname -m)" in
      x86_64) ARCH="amd64" ;;
      i?86) ARCH="i386" ;;
      aarch64) ARCH="arm64" ;;
      armv7l|armv6l) ARCH="armhf" ;;
      *) ARCH="$(uname -m)" ;;
    esac
  fi
fi

if grep -Eiq '^ID=kali([[:space:]]|=|$)' /etc/os-release; then
  DETECTED_DISTRO="kali"
elif grep -Eiq '^ID=debian([[:space:]]|=|$)' /etc/os-release && grep -Eiq '^VERSION_ID="?12([.]|"|$)' /etc/os-release; then
  DETECTED_DISTRO="debian-bookworm"
else
  echo "未找到已适配的 Linux 发行版资源。当前支持 Kali 系和 Debian 12 amd64。" >&2
  echo "Ubuntu、Fedora、Arch、Alpine 等系统不能直接安装 Kali 的 .deb。" >&2
  exit 1
fi

if [[ -n "$DISTRO_OVERRIDE" && "$DISTRO_OVERRIDE" != "$DETECTED_DISTRO" ]]; then
  echo "发行版参数 $DISTRO_OVERRIDE 与当前系统 $DETECTED_DISTRO 不匹配，已拒绝安装。" >&2
  echo "此参数只能用于明确选择当前系统对应的资源，不能把其他发行版的 .deb 强行安装进来。" >&2
  exit 1
fi
DISTRO="${DISTRO_OVERRIDE:-$DETECTED_DISTRO}"

case "$DISTRO" in
  kali|debian-bookworm) ;;
  *) echo "不支持的发行版资源: $DISTRO" >&2; exit 1 ;;
esac

if [[ "$DISTRO" == "debian-bookworm" && "$ARCH" != "amd64" ]]; then
  echo "当前仅提供 Debian 12 amd64 离线资源；Debian 12 $ARCH 不能使用 Kali 的 .deb。" >&2
  echo "请使用 Debian 自己的软件源在线安装，或在目标架构上准备匹配的 Debian 包。" >&2
  exit 1
fi

if [[ "$DISTRO" == "debian-bookworm" && "$ARCH" == "amd64" ]]; then
  DEB_DIR="$ROOT/linux/debian-bookworm-amd64"
else
  DEB_DIR="$ROOT/linux/kali-$ARCH"
fi
if [[ ! -d "$DEB_DIR" ]]; then
  echo "离线包中没有匹配架构 $ARCH 的资源目录。" >&2
  echo "已内置架构：$(cd "$ROOT/linux" 2>/dev/null && ls -d kali-* 2>/dev/null | sed 's/^kali-//' | tr '\n' ' ')" >&2
  exit 1
fi

if [[ "$DISTRO" == "debian-bookworm" && "$ARCH" == "amd64" ]]; then
  packages=(
    "$DEB_DIR/libudev1_252.39-1~deb12u2_amd64.deb"
    "$DEB_DIR/libwrap0_7.6.q-32_amd64.deb"
    "$DEB_DIR/libnsl2_1.3.0-2_amd64.deb"
    "$DEB_DIR/usb.ids_2025.07.26-0+deb12u1_all.deb"
    "$DEB_DIR/usbip_2.0+6.1.176-1_amd64.deb"
  )
else
  case "$ARCH" in
    amd64|i386|arm64|armhf)
      packages=(
        "$DEB_DIR/libudev1_261.2-1_${ARCH}.deb"
        "$DEB_DIR/libwrap0_7.6.q-37_${ARCH}.deb"
        "$DEB_DIR/usb.ids_2026.06.26-1_all.deb"
        "$DEB_DIR/usbip_2.0+7.0.12-2kali1_${ARCH}.deb"
      )
      ;;
    *)
      echo "不支持的架构: $ARCH" >&2
      exit 1
      ;;
  esac
fi

for package in "${packages[@]}"; do
  [[ -r "$package" ]] || { echo "缺少离线包: $package" >&2; exit 1; }
done

# Never remove dpkg lock files. If another package operation is active, stop
# before invoking dpkg so the user can wait for it to finish safely.
if command -v fuser >/dev/null 2>&1; then
  LOCK_USERS=""
  for lock_file in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do
    users="$(fuser "$lock_file" 2>/dev/null || true)"
    [[ -n "${users//[[:space:]]/}" ]] && LOCK_USERS+="${lock_file}: ${users}\n"
  done
  if [[ -n "$LOCK_USERS" ]]; then
    echo "dpkg 正被其他包管理进程占用，已停止离线安装。" >&2
    printf '%b' "$LOCK_USERS" >&2
    echo "请等待 apt/dpkg 完成后再重试；不要删除锁文件。" >&2
    exit 3
  fi
fi

echo "目标发行版资源: $DISTRO"
echo "目标架构: $ARCH"
echo "将安装以下离线包："
printf '  %s\n' "${packages[@]}"
dpkg -i "${packages[@]}" || {
  echo "离线 .deb 安装存在依赖或版本问题；请确认目标系统已有兼容的 libc6，并且资源与发行版匹配。" >&2
  exit 1
}

modprobe usbip-core 2>/dev/null || true
modprobe usbip-host 2>/dev/null || true
modprobe vhci-hcd 2>/dev/null || true
echo "Linux USB/IP 用户态组件安装完成（$ARCH）。请检查内核模块加载状态。"
