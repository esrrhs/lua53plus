#!/usr/bin/env bash
# Run against the CURRENT liblua.a; do not silently rebuild with different flags.
set -euo pipefail
cd "$(dirname "$0")/.."
flags="${EXTRA_CFLAGS:-}"
if [ "${1:-release}" = ltests ]; then
  flags="$flags -DGC_WITH_LTESTS -DLUA_USER_H=\"../testes/ltests/ltests.h\""
fi
libs="-lm"
if [ "$(uname -s)" != Darwin ]; then libs="$libs -ldl"; fi
mkdir -p validation-results
# flag-list splitting intentional; embedded quotes in -D are literal argv bytes.
${CC:-cc} -std=gnu99 -O2 -Wall -Wextra -Isrc $flags tests/gc_validate.c \
  src/liblua.a ${EXTRA_LDFLAGS:-} $libs -o validation-results/gc_validate
./validation-results/gc_validate
if [ "${1:-release}" = ltests ]; then
  # Assert SIGABRT specifically: a crash, loader error or exit(2) is NOT a pass.
  python3 - <<'PYNEG'
import subprocess, signal, resource
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
expected = {'barrier':'GC reference invariant failed', 'pause':'validpause', 'listprev':'listprev',
            'mandatory-major':'GC reference invariant failed', 'primary-alias':'tails[i]', 'remuv':'inrem'}
for fault, assertion in expected.items():
    p = subprocess.run(['./validation-results/gc_validate',fault],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    Path('validation-results/negative-'+fault+'.log').write_bytes(p.stdout)
    if p.returncode != -signal.SIGABRT:
        raise SystemExit('negative test '+fault+' expected SIGABRT, got '+str(p.returncode))
    if assertion.encode() not in p.stdout:
        raise SystemExit('negative test '+fault+' did not reach expected assertion '+assertion)
    print('negative checker test:',fault,'rejected by',assertion,'(SIGABRT)')
PYNEG
fi
