<div align="center">

# ion7-grammar

**Grammar engine for LuaJIT — compile regex, ABNF, EBNF, JSON Schema or Lua type annotations to GBNF, then constrain LLMs to valid output by construction.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![LuaJIT 2.1](https://img.shields.io/badge/LuaJIT-2.1-orange.svg)](https://luajit.org/)
[![ion7-core](https://img.shields.io/badge/depends%20on-ion7--core-red.svg)](https://github.com/Ion7-Labs/ion7-core)
[![Tests: 403](https://img.shields.io/badge/tests-403%20passing-brightgreen)](tests/)

<img src="assets/architecture.svg" alt="ion7-grammar architecture" width="640"/>

</div>

---

`ion7-core` gives you the sampler chain. `ion7-llm` gives you the chat pipeline. `ion7-grammar` is the layer between either of them and a model that can only emit syntactically valid output : every constructor produces an `ion7-core`-compatible GBNF string, and grammars compose freely.

What that buys you :

- **Eight grammar input formats, one output.** `from_type`, `from_json_schema`, `from_json_schema_native`, `from_regex`, `from_abnf`, `from_ebnf`, `from_enum`, `from_auto` — all return the same composable `Grammar_obj`. Drop a verbatim RFC ABNF or W3C-style EBNF in and out comes a GBNF the sampler accepts.
- **AST-level composition.** `union`, `sequence`, `wrap`, `interleave`, `repeat_g`, `optional`, `annotate`, `merge` — all chainable. Internal rule names are auto-prefixed so composing two grammars never breaks references.
- **Multi-tenant safe runtime.** `Backtrack` (KV rollback / IterGen / CRANE) and `DCCD` (Draft-Conditioned Constrained Decoding) operate on a single `seq_id` you pass at construction. Run them on seq 3 and seq 0's KV row stays untouched — drops straight into ion7-llm's `Pool`.
- **Stateful grammars.** `GrammarContext` grows with the conversation : register enums (`learn_enum`), tables (`learn_table`), tools (`learn_tool`), `snapshot` / `restore` for branching scenarios.
- **Tooling that pays for itself.** Pure-Lua fuzzer (`Grammar.fuzz`), annotated GBNF debug, ASCII rule-dependency tree, grammar diff, character / value / pattern complement.
- **Library, not a server.** No HTTP, no SSE, no CLI binary. ion7-grammar is meant to be embedded in your application — drop into agent loops, batch jobs, schema-validated prompt builders.

## Quick taste

```lua
local Grammar = require "ion7.grammar"

-- From a Lua type annotation
local g = Grammar.from_type({
    name   = "string",
    age    = "integer",
    status = { enum = { "active", "inactive" } },
})

-- Or from a verbatim RFC 3339 ABNF fragment
local rfc3339 = Grammar.from_abnf([[
date-fullyear = 4DIGIT
date-month    = 2DIGIT
date-mday     = 2DIGIT
full-date     = date-fullyear "-" date-month "-" date-mday
]])

-- Hand off to ion7-core's sampler
local sampler = ion7.Sampler.chain()
    :grammar(g:to_gbnf(), "root", vocab)
    :greedy()
    :build()
```

Ten progressive examples in [`examples/`](examples/) walk every layer — every constructor, composition, fuzz + debug, real-model integration, backtracking, DCCD, an SQL agent, plus the new RFC ABNF and W3C EBNF showcases.

## What's covered

| Surface | Status | Where to look |
|---|:---:|---|
| `from_type` — Lua type annotations | ✅ | [`from/types.lua`](src/ion7/grammar/from/types.lua), [`02_from.lua`](tests/02_from.lua) |
| `from_json_schema` / `from_json_schema_native` | ✅ | [`from/json/`](src/ion7/grammar/from/json/), [`02_from.lua`](tests/02_from.lua) |
| `from_regex` — ERE/PCRE subset on LPeg | ✅ | [`from/regex.lua`](src/ion7/grammar/from/regex.lua), [`02_from.lua`](tests/02_from.lua) |
| `from_abnf` — RFC 5234 §4 | ✅ | [`from/abnf.lua`](src/ion7/grammar/from/abnf.lua), [`03_from_abnf.lua`](tests/03_from_abnf.lua) |
| `from_ebnf` — W3C-style EBNF | ✅ | [`from/ebnf.lua`](src/ion7/grammar/from/ebnf.lua), [`04_from_ebnf.lua`](tests/04_from_ebnf.lua) |
| `from_auto` — heuristic format detection | ✅ | [`init.lua`](src/ion7/grammar/init.lua), [`05_from_auto.lua`](tests/05_from_auto.lua) |
| `from_enum` / `from_json_enum` / `from_tools` | ✅ | [`from/dynamic.lua`](src/ion7/grammar/from/dynamic.lua), [`02_from.lua`](tests/02_from.lua) |
| AST primitives + `Builder` (O(1) rule replacement) | ✅ | [`ast/`](src/ion7/grammar/ast/), [`01_ast.lua`](tests/01_ast.lua) |
| `compose` — union / sequence / wrap / interleave / repeat / annotate | ✅ | [`compose.lua`](src/ion7/grammar/compose.lua), [`06_grammar.lua`](tests/06_grammar.lua) |
| `except` — character / value / prefix / pattern complement | ✅ | [`except.lua`](src/ion7/grammar/except.lua), [`06_grammar.lua`](tests/06_grammar.lua) |
| `runtime.GrammarContext` — stateful grammar with snapshot / restore | ✅ | [`runtime/context.lua`](src/ion7/grammar/runtime/context.lua), [`08_runtime.lua`](tests/08_runtime.lua) |
| `runtime.Backtrack` — per-seq KV rollback (IterGen / CRANE) | ✅ | [`runtime/backtrack.lua`](src/ion7/grammar/runtime/backtrack.lua), [`08_runtime.lua`](tests/08_runtime.lua) |
| `runtime.DCCD` — Draft-Conditioned Constrained Decoding (arXiv:2603.03305) | ✅ | [`runtime/dccd.lua`](src/ion7/grammar/runtime/dccd.lua), [`11_dccd_model.lua`](tests/11_dccd_model.lua) |
| `dev.fuzz` — pure-Lua random generator + satisfiability check | ✅ | [`dev/fuzz.lua`](src/ion7/grammar/dev/fuzz.lua), [`07_dev.lua`](tests/07_dev.lua) |
| `dev.debug` — annotated GBNF, rule tree, grammar diff | ✅ | [`dev/debug.lua`](src/ion7/grammar/dev/debug.lua), [`07_dev.lua`](tests/07_dev.lua) |

## Install

ion7-grammar is a pure-Lua library on top of ion7-core, with two thin C deps via luarocks. The fastest way :

```bash
# 1. ion7-core (source-of-truth for the FFI bridge + libllama).
git clone https://github.com/Ion7-Labs/ion7-core
cd ion7-core && make build && cd ..

# 2. ion7-grammar next to it.
git clone https://github.com/Ion7-Labs/ion7-grammar
cd ion7-grammar
luarocks install --local lua-cjson lpeg

# 3. Pure-Lua suite, no model.
bash tests/run_all.sh
```

For luarocks installs, sibling-checkout layouts, and the model-dependent suites, see **[`INSTALL.md`](INSTALL.md)**.

## Compatibility

| Component | Requirement |
|---|---|
| LuaJIT | 2.1 (any post-2017 build) |
| ion7-core | matched release (1.0+) |
| LPeg | 1.0+ |
| lua-cjson | 2.1+ (transitive via ion7-core) |
| OS | whatever ion7-core builds on (Linux / macOS / Windows) |
| Models | any GGUF that ion7-core's sampler can constrain on |

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — layered design, AST, format pipeline, runtime, multi-session safety (four annotated diagrams)
- [`INSTALL.md`](INSTALL.md) — install paths, sibling-checkout layouts, troubleshooting
- [`examples/README.md`](examples/README.md) — guided tour of the ten example scripts

## License

[MIT](LICENSE). `ion7-grammar` builds on [ion7-core](https://github.com/Ion7-Labs/ion7-core), itself built on [llama.cpp](https://github.com/ggml-org/llama.cpp) by Georgi Gerganov and contributors.
