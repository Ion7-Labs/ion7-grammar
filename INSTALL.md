# Installing ion7-grammar

ion7-grammar runs on LuaJIT 2.1 and depends on three external libraries.
This document lists each path users actually take.

---

## 1. Prerequisites

| Component | Required | Notes |
|---|---|---|
| **LuaJIT 2.1** | yes | `luajit -v` should print `LuaJIT 2.1.X`. |
| **luarocks** | yes | Used to fetch LPeg + lua-cjson. Use `--local` to scope to your home directory. |
| **ion7-core** | yes | Sibling clone or installed rock. ion7-grammar consumes its FFI bridge for `from_json_schema_native` and the ion7-core runtime objects for `Backtrack` / `DCCD`. |
| **LPeg ≥ 1.0** | yes | Powers `from_regex`, `from_abnf`, `from_ebnf`. |
| **lua-cjson ≥ 2.1** | yes | Pulled in transitively via ion7-core; keep it at 2.1 for the empty-table-as-object behaviour ion7 relies on. |

You only need libllama / the ion7-core C bridge when actually running a
model — pure-Lua paths (compile a grammar, fuzz it, inspect it) work
without any binary dependency beyond the rocks above.

---

## 2. From luarocks

```bash
luarocks install --local lua-cjson
luarocks install --local lpeg
luarocks install --local ion7-core      # bring its bridge + libllama
luarocks install --local ion7-grammar
```

Verify :

```bash
eval "$(luarocks path --local)"
luajit -e 'print(require("ion7.grammar")._VERSION)'
```

`--local` puts every artifact under `~/.luarocks/` — the `eval` line
above prepends that to `LUA_PATH` / `LUA_CPATH` so `require` finds
them. Skip `--local` and run the same commands under `sudo` for a
system-wide install ; do not mix the two.

---

## 3. From source — sibling checkout

The setup the project tests with day-to-day :

```
~/code/
├── ion7-core/         # cloned from Ion7-Labs/ion7-core
├── ion7-grammar/      # this repo
└── ion7-llm/          # optional, only for the integration smoke test
```

Run with the in-tree paths :

```bash
cd ion7-grammar
luarocks install --local lua-cjson lpeg
luajit examples/01_basics.lua          # pure-Lua, no model
```

The example (and every test file) probes `../ion7-core/src/` and
`../../ion7-core/src/` for ion7-core. Override with `ION7_CORE_SRC` if
your layout differs :

```bash
ION7_CORE_SRC=/abs/path/to/ion7-core/src \
  luajit tests/03_from_abnf.lua
```

---

## 4. Running the model-dependent tests

`tests/10_model.lua` and `tests/11_dccd_model.lua` need libllama and a
real GGUF :

```bash
ION7_MODEL=/path/to/your.gguf \
ION7_LIBLLAMA_PATH=/path/to/libllama.so \
ION7_BRIDGE_PATH=/path/to/ion7_bridge.so \
  bash tests/run_all.sh
```

The `ION7_*_PATH` overrides are only needed when ion7-core is in a
sibling checkout (the bundled libraries come from the rock when
installed via luarocks).

---

## 5. Troubleshooting

**`module 'ion7.vendor.json' not found`**
ion7-grammar pulls cjson through ion7-core. Either ion7-core is missing
from the path, or `lua-cjson` is not installed. Re-run
`luarocks install --local lua-cjson` and confirm with
`luajit -e 'require "cjson"'`.

**`module 'lpeg' not found`**
Install LPeg : `luarocks install --local lpeg`. The C build needs a
working `gcc` toolchain — install `build-essential` (Debian/Ubuntu) or
the equivalent for your platform.

**`[ion7-core] libllama not found`**
The ion7-core FFI loader could not locate `libllama.so`. Set
`ION7_LIBLLAMA_PATH` to the absolute path, or move ion7-core's
`vendor/llama.cpp/build/bin/` onto your `LD_LIBRARY_PATH`. Pure-Lua
paths in ion7-grammar do not need this — only `from_json_schema_native`
and the runtime objects (`Backtrack`, `DCCD`) do.
