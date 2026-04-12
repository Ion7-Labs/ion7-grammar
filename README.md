# ion7-grammar

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![LuaJIT](https://img.shields.io/badge/LuaJIT-2.1-orange.svg)](https://luajit.org/)
[![ion7-core](https://img.shields.io/badge/ion7--core-1.2-brightgreen.svg)](https://github.com/Ion7-Labs/ion7-core)
[![API Reference](https://img.shields.io/badge/docs-grammar-blueviolet)](https://ion7-labs.github.io/grammar/)

**GBNF grammar engine for LuaJIT. Build grammars from types, schemas, and regex. Constrain LLMs to valid output by construction.**

```lua
local Grammar = require "ion7.grammar"

local g = Grammar.from_type({
    name   = "string",
    age    = "integer",
    status = { enum = { "active", "inactive" } },
})

local sampler = ion7.Sampler.chain()
    :grammar(g:to_gbnf(), "root", vocab)
    :temp(0.2):dist(42):build(vocab)
```

---

## Features

- **Constructors** — `from_type`, `from_json_schema`, `from_regex`, `from_enum`, `from_tools`, `from_json_schema_native`, `raw`
- **Composition** — `union`, `sequence`, `wrap`, `interleave`, `repeat_g`, `optional`, `annotate`, `merge` — all chainable on `Grammar_obj`
- **Runtime grammars** — `GrammarContext`: grows with conversation turns, snapshot/restore
- **Backtracking** — KV cache rollback to resample any fragment (IterGen / CRANE pattern)
- **DCCD** — Draft-Conditioned Constrained Decoding with `close_thinking` for Qwen3.5 / DeepSeek-R1

> **Note (DCCD):** The core two-pass algorithm follows [arXiv:2603.03305](https://arxiv.org/abs/2603.03305).
> The `best_of_k` selection uses output length as a proxy for feasible mass, rather than the
> cumulative log-feasible-mass criterion (`Σ log ᾱ_t`) from the paper - the sampler does not
> currently expose per-step feasible mass. For `k=1` (default) this has no effect.
> `close_thinking` and the speculative n-gram draft path are ion7-specific extensions not in the paper.
- **Tooling** — fuzzer, annotated GBNF debug, rule tree, grammar diff, complement

Full API reference: **[ion7-labs.github.io/grammar/](https://ion7-labs.github.io/grammar/)**

---

## Quick start

```bash
git clone https://github.com/ion7-labs/ion7-grammar
cd ion7-grammar
luajit examples/01_basics.lua        # no model required
```

See [`examples/`](examples/) for 8 worked examples (01–04 model-free, 05–08 with ion7-core).

---

## Tests

```bash
make test                            # 301 pure-Lua tests, no model
luajit tests/test_dccd_model.lua     # DCCD end-to-end (requires ION7_MODEL + ION7_CORE)
```

---

## Compatibility

| Component | Requirement |
|-----------|-------------|
| LuaJIT | 2.1+ |
| ion7-core | 1.2+ (required for `Backtrack`, `DCCD`, `from_json_schema_native`) |
| llama.cpp | b8600+ (via ion7-core) |
| OS | Linux, macOS |

---

MIT License
