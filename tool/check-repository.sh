#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
check() {
  local message="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$message"
  else
    printf 'FAIL: %s\n' "$message" >&2
    fail=1
  fi
}

check "pubspec.lock is present" test -f pubspec.lock
check "offline checksum manifest is present" test -f offline/SHA256SUMS

if find . -type f \
    \( -path './.git/*' -o -path './.dart_tool/*' -o -path './build/*' \
       -o -path './dist/*' -o -path './.tmp/*' -o -path './.wine*/*' \
       -o -path './third_party/*/.git/*' \) -prune -o \
    -type f \( -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \) \
    -print -quit | grep -q .; then
  printf 'FAIL: private key material found in source tree\n' >&2
  fail=1
else
  printf 'PASS: no private key material found in source tree\n'
fi

if find . -type d -name .git -not -path './.git' -not -path './.git/*' -print -quit | grep -q .; then
  printf 'FAIL: nested Git metadata exists under third_party\n' >&2
  printf '      remove it before vendoring; revisions are tracked in third_party/SOURCES.lock.\n' >&2
  fail=1
fi

if command -v sha256sum >/dev/null 2>&1; then
  check "offline resources match SHA256SUMS" bash -c 'cd offline && sha256sum -c SHA256SUMS >/dev/null'
else
  printf 'SKIP: sha256sum is not available\n'
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
printf 'Repository checks passed.\n'
