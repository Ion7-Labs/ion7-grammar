# ion7-grammar

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![LuaJIT](https://img.shields.io/badge/LuaJIT-2.1-orange.svg)](https://luajit.org/)
[![ion7-core](https://img.shields.io/badge/ion7--core-1.2-brightgreen.svg)](https://github.com/Ion7-Labs/ion7-core)

**GBNF grammar engine for LuaJIT. Build grammars from types, schemas, and regex. Constrain LLMs to valid output by construction.**

```lua
local Grammar = require "ion7.grammar"

-- Build a grammar from a Lua type annotation
local g = Grammar.from_type({
    name   = "string",
    age    = "integer",
    status = { enum = { "active", "inactive" } },
})

-- Pass to ion7-core sampler — the model cannot output invalid JSON
local sampler = ion7.Sampler.chain()
    :grammar(g:to_gbnf(), "root", vocab)
    :temp(0.2):dist(42):build(vocab)
```

---

## Why ion7-grammar?

Writing GBNF by hand is error-prone. ion7-grammar generates correct GBNF from things you already have:

- **Lua type annotations** → JSON object grammar in one call
- **JSON Schema** → full draft-07 → GBNF conversion
- **Regex** → ERE patterns compiled to grammar
- **Runtime values** → model can only output values that exist in your DB

Without ion7-grammar, you write fragile string templates. With it, you write Lua data structures and get guaranteed-valid output.

---

## Features

**Grammar construction**
- Lua type annotations → GBNF (`from_type`)
- JSON Schema draft-07 → GBNF (`from_json_schema`)
- ERE regex → GBNF (`from_regex`)
- String/enum whitelists, longest-first order (`from_enum`, `from_json_enum`)
- Tool-call grammar from a registry (`from_tools`)
- JSON Schema via C++ libcommon backend (`from_json_schema_native`) — handles `$ref`, `allOf`, `anyOf`
- Tool-call grammar + bound JSON parser in one call (`tool_pipeline`)
- Auto-derive CRANE trigger words from grammar AST (`trigger_words`)
- Manual rule builder with AST primitives (`builder`)
- Raw GBNF passthrough (`raw`)

**Composition**
- All operators return `Grammar_obj` and chain: `union`, `sequence`, `wrap`, `interleave`, `repeat_g`, `optional`, `annotate`
- Fluent: `g:union(other)`, `g:then_(other, sep)`
- Merge rules between grammars (`g:merge(other)`)

**Runtime grammars**
- `GrammarContext`: stateful grammar that grows with conversation turns
- Snapshot/restore for branching dialogue paths
- Table/column/tool registration and removal

**Advanced generation**
- `Backtrack`: KV cache rollback to resample any grammar fragment (IterGen ICLR 2025 / CRANE ICML 2025 pattern)
- `DCCD`: Draft-Conditioned Constrained Decoding — unconstrained draft injected into KV, constrained pass on augmented context (arXiv:2603.03305). `close_thinking` support for Qwen3.5/DeepSeek-R1. Validated end-to-end with `test_dccd_model.lua`.

**Tooling**
- Grammar fuzzer: random valid strings without a model (`Grammar.fuzz`)
- Debug: annotated GBNF, rule tree, grammar diff (`Grammar.debug`, `Grammar.analyze`, `Grammar.tree`, `Grammar.diff`)
- Grammar complement: exclude values or patterns (`Grammar.except_chars`, `Grammar.except_values`, `Grammar.except_pattern`)

---

## Quick start

```bash
git clone https://github.com/ion7-labs/ion7-grammar
cd ion7-grammar
luajit examples/01_basics.lua
```

No model required for examples 01–04.

```bash
# With a model (requires ion7-core)
ION7_MODEL=/path/to/model.gguf \
ION7_CORE=/path/to/ion7-core \
  luajit examples/05_with_model.lua
```

---

## Usage

### Constrained generation

```lua
local Grammar = require "ion7.grammar"
local ion7    = require "ion7.core"

local g = Grammar.from_type({ name = "string", score = "integer" })

local sampler = ion7.Sampler.chain()
    :grammar(g:to_gbnf(), "root", vocab)  -- vocab is a table, NOT vocab._ptr
    :temp(0.0):dist(42):build(vocab)

-- Never call sampler:accept() after sample() — chain already does it internally
local tok = sampler:sample(ctx:ptr(), -1)
ctx:decode_single(tok, 0)
```

### Dynamic grammar from runtime data

```lua
local gc = Grammar.context()

-- Register values that actually exist in your system
gc:learn_table("users", db:get_columns("users"))
gc:learn_enum("status", pipeline:valid_states())

-- Grammar updates automatically — model cannot hallucinate column names
local sampler = ion7.Sampler.chain()
    :grammar(gc:current():to_gbnf(), "root", vocab)
    :temp(0.2):dist():build(vocab)
```

### KV cache backtracking

```lua
local bt = Grammar.backtrack(ctx, vocab, sampler)

bt:checkpoint("table-name")
bt:forward(function(p) return p:find("%s") end)

-- If validation fails, restore KV and resample
bt:constrain("table-name", function(text)
    return db:has_table(text:match("(%w+)$"))
end)
```

### DCCD (Draft-Conditioned Constrained Decoding)

**Thinking models (Qwen3.5, DeepSeek-R1):** the generation prefix opens a `<think>` block that the draft pass never closes. Without `close_thinking = true`, the constrained pass runs while the model believes it is still reasoning and produces wrong output. Setting this option injects `\n</think>\n` between draft injection and the constrained pass.

```lua
local dc = Grammar.dccd(ctx, vocab, {
    draft_sampler     = free_sampler,    -- unconstrained
    constrain_sampler = grammar_sampler, -- GBNF-constrained
    max_draft_tokens  = 128,
    close_thinking    = true,  -- required for Qwen3.5 / DeepSeek-R1
})

local result = dc:generate()
print(result.text)         -- guaranteed grammar-valid
print(result.draft)        -- unconstrained draft (for debugging)
print(result.n_close_toks) -- tokens injected to close <think> (0 if not a thinking model)
```

---

## Module structure

```
src/ion7/grammar/
├── init.lua            — entry point, all public constructors and re-exports
├── grammar_obj.lua     — Grammar_obj type: to_gbnf, merge, fuzz, inspect, trigger_words
├── compose.lua         — composition operators: union, sequence, wrap, interleave, repeat_g…
├── except.lua          — grammar complement: except_chars, except_values, except_pattern, except_prefix
│
├── ast/                — low-level AST layer (no LLM dependency)
│   ├── init.lua        — re-exports all AST submodules
│   ├── nodes.lua       — node constructors: literal, char, ref, seq, alt, rep, group, rule
│   ├── builder.lua     — fluent rule builder: Builder:rule(), :compile()
│   ├── compiler.lua    — AST → GBNF string
│   └── walk.lua        — AST traversal and analysis utilities
│
├── from/               — grammar constructors (input → Grammar_obj)
│   ├── regex.lua       — ERE regex → AST (to_ast, to_gbnf)
│   ├── json/           — JSON Schema draft-07 → GBNF (Lua pure)
│   ├── types.lua       — Lua type annotations → Grammar (from_type, from_function)
│   └── dynamic.lua     — from_enum, from_json_enum, from_schema, from_tools
│
├── runtime/            — stateful and advanced generation (ion7-core optional/required)
│   ├── context.lua     — GrammarContext: learn_enum, learn_table, snapshot/restore
│   ├── backtrack.lua   — KV backtracking: checkpoint, forward, constrain, run
│   └── dccd.lua        — Draft-Conditioned Constrained Decoding
│
└── dev/                — development and validation tools
    ├── fuzz.lua        — grammar fuzzer: fuzz, fuzz_one, fuzz_validate
    └── debug.lua       — inspect, analyze, tree, diff
```

The full public API contract is in [`spec/PUBLIC_API.md`](spec/PUBLIC_API.md).

---

## Examples

| File | Concepts | Model | Level |
|------|----------|-------|-------|
| [01_basics.lua](examples/01_basics.lua) | `from_enum`, `from_regex`, `from_type`, `from_json_schema`, `from_builder`, `raw` | No | ★☆☆☆ |
| [02_composition.lua](examples/02_composition.lua) | `union`, `sequence`, `wrap`, `interleave`, `repeat_g`, `optional`, `annotate`, `merge` | No | ★★☆☆ |
| [03_dynamic.lua](examples/03_dynamic.lua) | `from_enum` with runtime data, `from_tools`, `GrammarContext`, snapshot/restore | No | ★★☆☆ |
| [04_fuzz_and_debug.lua](examples/04_fuzz_and_debug.lua) | `fuzz`, `fuzz_one`, `fuzz_validate`, `debug`, `analyze`, `tree`, `diff` | No | ★★☆☆ |
| [05_with_model.lua](examples/05_with_model.lua) | Full pipeline: build → fuzz-validate → constrain sampler → generate | Yes | ★★★☆ |
| [06_backtrack.lua](examples/06_backtrack.lua) | `Backtrack`: KV snapshot, `checkpoint`, `forward`, `constrain`, `run`, `backward` | Yes | ★★★★ |
| [07_dccd.lua](examples/07_dccd.lua) | `DCCD`: draft pass, KV injection, constrained pass, `best_of(k)`, streaming | Yes | ★★★★ |
| [08_sql_agent.lua](examples/08_sql_agent.lua) | Complete app: dynamic schema grammar, SQL hallucination prevention | Yes | ★★★★ |

---

## Tests

```bash
# Pure Lua — no model required (301 tests)
luajit tests/test_pure.lua

# Individual spec files
luajit tests/spec/test_ast.lua
luajit tests/spec/test_from.lua
luajit tests/spec/test_grammar.lua
luajit tests/spec/test_runtime.lua
luajit tests/spec/test_dev.lua

# With model (requires ION7_MODEL and ION7_CORE)
luajit tests/test_dccd_model.lua
```

Test specs mirror the source structure: `test_ast` covers the AST layer, `test_from` covers all constructors, `test_grammar` covers `Grammar_obj` and composition, `test_runtime` covers `GrammarContext` and DCCD, `test_dev` covers the fuzzer, debug tools, and `Except`.

---

## Compatibility

| Component | Requirement |
|-----------|-------------|
| LuaJIT | 2.1+ |
| ion7-core | 1.2+ (required for `Backtrack`, `DCCD`, `from_json_schema_native`) |
| llama.cpp | b8600+ (via ion7-core) |
| OS | Linux, macOS |

### Known llama.cpp constraints

- Rule names must match `[a-z][a-z0-9-]+` — **hyphens only, no underscores**
- Pass `vocab` table (not `vocab._ptr`) to `:grammar(gbnf, root, vocab)`
- `llama_sampler_sample()` on a chain already calls accept internally — **never call `sampler:accept()` separately**
- The `ws` rule is only auto-injected when referenced — orphan rules crash the sampler

---

## Licensing

MIT License — free to use in any project, open source or commercial.
