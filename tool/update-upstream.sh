#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The release tree vendors source snapshots, so it does not need to contain
# nested Git repositories. During development this also accepts the old
# shallow-checkout layout and updates it in place.
declare -A upstream=(
  [k-francis-usbip-gui]='https://github.com/K-Francis-H/usbip-gui.git'
  [snakeusbip]='https://github.com/Snakefoxu/SnakeUSBIP.git'
  [snakeusbip-server]='https://github.com/Snakefoxu/SnakeUSBIP-Server.git'
)

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

for name in "${!upstream[@]}"; do
  dir="third_party/$name"
  url="${upstream[$name]}"
  mkdir -p "$dir"
  if [[ -d "$dir/.git" ]]; then
    echo "Updating Git checkout: $dir"
    git -C "$dir" pull --ff-only
    revision="$(git -C "$dir" rev-parse HEAD)"
  else
    checkout="$tmp_root/$name"
    echo "Refreshing vendored snapshot: $dir"
    git clone --depth 1 "$url" "$checkout"
    # Make the vendored directory match the checkout exactly. This also
    # removes files deleted upstream instead of leaving stale snapshots.
    find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    # Copy the snapshot without importing the checkout's .git directory.
    find "$checkout" -mindepth 1 -maxdepth 1 ! -name .git \
      -exec cp -a {} "$dir/" \;
    revision="$(git -C "$checkout" rev-parse HEAD)"
  fi
  printf '  %s %s\n' "$name" "$revision"
done

cat <<'EOF'

Review the source changes and update third_party/SOURCES.lock with the printed
revisions before committing. Keep each upstream license and notice file.
EOF
