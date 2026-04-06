# ion7-grammar

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![LuaJIT](https://img.shields.io/badge/LuaJIT-2.1-orange.svg)](https://luajit.org/)
[![ion7-core](https://img.shields.io/badge/ion7--core-1.0-brightgreen.svg)](https://github.com/Ion7-Labs/ion7-core)

**GBNF grammar engine for LuaJIT. Build grammars from types, schemas, and regex. Constrain LLMs to valid output by construction.**

```lua
local Grammar = require "ion7.grammar"

-- Build a grammar from a Lua type annotation
local g = Grammar.from_type({
    name   = "string",
    age    = "integer",
    status = { enum = { "active", "inactive" } },
})

-- Pass to ion7-core sampler - the model cannot output invalid JSON
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
- Grammar complement: exclude values or patterns (`Except`)

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
  luajit examples/05_constrained.lua
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

-- Never call sampler:accept() after sample() - chain already does it internally
local tok = sampler:sample(ctx:ptr(), -1)
ctx:decode_single(tok, 0)
```

### Dynamic grammar from runtime data

```lua
local gc = Grammar.context()

-- Register values that actually exist in your system
gc:learn_table("users", db:get_columns("users"))
gc:learn_enum("status", pipeline:valid_states())

-- Grammar updates automatically - model cannot hallucinate column names
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
    close_thinking    = true,  -- required for Qwen3.5 / DeepSeek-R1 and any thinking model
})

local result = dc:generate()
print(result.text)         -- guaranteed grammar-valid
print(result.draft)        -- unconstrained draft (for debugging)
print(result.n_close_toks) -- tokens injected to close <think> block (0 if not a thinking model)
```

---

## Module structure

```
src/ion7/grammar/
├── init.lua        - entry point, all public constructors
├── ast.lua         - AST nodes (literal, char, ref, seq, alt, rep)
├── compiler.lua    - AST → GBNF string
├── builder.lua     - fluent rule builder
├── regex.lua       - ERE regex → AST
├── json.lua        - JSON Schema draft-07 → GBNF
├── types.lua       - Lua type annotations → Grammar
├── dynamic.lua     - from_enum, from_json_enum, from_tools
├── compose.lua     - composition operators
├── context.lua     - GrammarContext (stateful, snapshot/restore)
├── backtrack.lua   - KV cache backtracking (IterGen/CRANE)
├── dccd.lua        - Draft-Conditioned Constrained Decoding
├── fuzz.lua        - grammar fuzzer (zero LLM)
├── debug.lua       - inspect, analyze, tree, diff
└── except.lua      - grammar complement operators
```

The public API contract is documented in [`spec/PUBLIC_API.md`](spec/PUBLIC_API.md).

---

## Compatibility

| Component | Requirement |
|-----------|-------------|
| LuaJIT | 2.1+ |
| ion7-core | 1.1+ (required for Backtrack, DCCD, from_json_schema_native) |
| llama.cpp | b8600+ (via ion7-core) |
| OS | Linux, macOS |

### Known llama.cpp constraints

- Rule names must match `[a-z][a-z0-9-]+` - **hyphens only, no underscores**
- Pass `vocab` table (not `vocab._ptr`) to `:grammar(gbnf, root, vocab)`
- `llama_sampler_sample()` on a chain already calls accept internally - **never call `sampler:accept()` separately**
- The `ws` rule is only auto-injected when referenced - orphan rules crash the sampler

---

## Licensing

MIT License — free to use in any project, open source or commercial.
