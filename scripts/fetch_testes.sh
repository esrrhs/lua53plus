#!/usr/bin/env bash
# Fetch official PUC-Lua 5.3.4 testes into ./testes and apply lua53plus adaptations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

URL="https://www.lua.org/tests/lua-5.3.4-tests.tar.gz"
SHA256="b80771238271c72565e5a1183292ef31bd7166414cd0d43a8eb79845fa7f599f"
TGZ="${TMPDIR:-/tmp}/lua-5.3.4-tests.tar.gz"

# lua.org is occasionally unreachable from some CI runners (commonly an
# IPv6 connect timeout). Prefer IPv4, then fall back to the default stack.
# Always verify SHA-256 before extracting. Do not skip official testes.
# Avoid empty bash arrays: macOS ships bash 3.2, where "${arr[@]}" with
# set -u aborts as "unbound variable" and skipped the default-stack retry.
ok=0
for attempt in 1 2 3; do
  echo "Downloading $URL (ipv4, attempt $attempt) ..."
  if curl -fsSL -4 --connect-timeout 20 --max-time 180 -o "$TGZ" "$URL"; then
    ok=1
    break
  fi
  echo "curl failed (ipv4, attempt $attempt)" >&2
  echo "Downloading $URL (default, attempt $attempt) ..."
  if curl -fsSL --connect-timeout 20 --max-time 180 -o "$TGZ" "$URL"; then
    ok=1
    break
  fi
  echo "curl failed (default, attempt $attempt)" >&2
  if [ "$attempt" -lt 3 ]; then
    echo "retrying in $((attempt * 5))s ..." >&2
    sleep $((attempt * 5))
  fi
done
if [ "$ok" -ne 1 ]; then
  echo "failed to download $URL after IPv4 and default retries" >&2
  exit 1
fi
echo "$SHA256  $TGZ" | sha256sum -c -

rm -rf testes
mkdir -p testes
tar -xzf "$TGZ" -C testes --strip-components=1
chmod -R u+w testes

# Adapt ltests for lua53plus extra gray lists + generational list awareness.
python3 scripts/patch_ltests.py

cp -f scripts/TESTES.md testes/README.md
echo "testes ready at $ROOT/testes"
