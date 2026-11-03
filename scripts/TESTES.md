# Official PUC-Lua 5.3.4 testes

## Fetch / refresh

```bash
./scripts/fetch_testes.sh
```

Downloads https://www.lua.org/tests/lua-5.3.4-tests.tar.gz, verifies SHA-256
`b80771238271c72565e5a1183292ef31bd7166414cd0d43a8eb79845fa7f599f`, extracts
to `./testes/`, and patches `ltests/ltests.c` for lua53plus gray lists.

`./testes/` is gitignored — do not vendor the tarball into git.

## Basic suite (no internal `T` module)

```bash
make linux          # or macosx
make test-testes-basic   # runs: lua -e'_U=true' all.lua
```

## Complete suite (with `T` / `lua_checkmemory`)

```bash
./scripts/fetch_testes.sh
./scripts/build_with_ltests.sh linux
make test-testes    # builds testes/libs/*.so, runs lua -e'_port=true' all.lua
```

CI uses `_port=true` so non-portable checks (notably `files.lua` invalid
`stdin:seek` when the runner attaches a seekable stdin) are skipped.

## Adaptations

1. **`markgrays`**: also walks `g->grayatomic` and `g->oldweak`.
2. **CI `_port=true`**: skip non-portable I/O assumptions.
3. **`lua_checkmemory`**: walks `oldgc` / `oldfinobj` / `tobeswept` /
   `tobesweptfin` / `remudata`; `checkobject` allows non-white `isold`
   objects at `GCSpause`; `testobjref1` allows old-black → young-white
   (TOUCHEDBIT / `oldweak` rescans). Fuzz/e2e still stress barriers.

## Optional: git submodule alternative

```bash
# Instead of the tarball script, you may vendor a mirror:
# git submodule add <mirror-url> testes
# then re-apply the markgrays patch from scripts/fetch_testes.sh
```
