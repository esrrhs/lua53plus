# lua53plus end-to-end language suite (non-GC)

Focused Lua scripts under feature folders, driven by `run_all.lua`.

```text
./src/lua tests/e2e/run_all.lua
```

## Layout

| Area | Path |
|------|------|
| Lexical / syntax | `lexical/` (strings, numbers, comments, labels/goto) |
| Expressions | `expressions/` (operators, precedence, short-circuit, vararg) |
| Statements | `statements/` (control, loops, assign) |
| Functions | `functions/` (closures, tail calls, methods, multiple returns) |
| Tables | `tables/` (constructors, length, iterators, metamethods) |
| Coroutines | `coroutines/` |
| Modules | `modules/` + `fixtures/modpack/` |
| Errors | `errors/` |
| Environments | `env/` |
| load / dump | `load/` |
| Stdlib | `stdlib/` (string, table, math, bit32, utf8, os, io, debug) |
| Userdata | `stdlib/userdata_note.lua` — portable checks; full bare userdata needs `tests/t_udata.so` (optional) |

GC behavior is covered by `tests/test_gc_fuzz.lua`, not this suite.
