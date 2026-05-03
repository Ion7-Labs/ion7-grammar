# ion7-grammar examples

Ten progressive scripts that walk every layer of the public API. Each
one is runnable from the project root with no extra setup beyond a
model path (when needed).

## Setup

```bash
# Examples 01-04, 09-10 are pure-Lua — no model required.
cd /path/to/ion7-grammar

# Examples 05-08 need a real model and ion7-core.
export ION7_MODEL=/path/to/model.gguf
export ION7_CORE_SRC=/abs/path/to/ion7-core/src   # only if not a sibling checkout
```

ion7-grammar consumes ion7-core for `from_json_schema_native`, the
runtime objects (`Backtrack`, `DCCD`) and the bundled `ion7.vendor.json`
wrapper. Run examples from the **project root** :

```bash
luajit examples/01_basics.lua
```

## Examples

| File | Concepts | Model | Difficulty |
|---|---|:---:|:---:|
| [01_basics.lua](01_basics.lua) | `from_enum`, `from_regex`, `from_type`, `from_json_schema`, `from_builder`, `raw` | No | ★☆☆☆ |
| [02_composition.lua](02_composition.lua) | `union`, `sequence`, `wrap`, `interleave`, `repeat_g`, `optional`, `annotate`, `merge` | No | ★★☆☆ |
| [03_dynamic.lua](03_dynamic.lua) | `from_enum` with runtime data, `from_tools`, `GrammarContext`, snapshot/restore | No | ★★☆☆ |
| [04_fuzz_and_debug.lua](04_fuzz_and_debug.lua) | `fuzz`, `fuzz_one`, `fuzz_validate`, `debug`, `analyze`, `tree`, `diff` | No | ★★☆☆ |
| [05_with_model.lua](05_with_model.lua) | Full pipeline : build → fuzz-validate → constrain sampler → generate | Yes | ★★★☆ |
| [06_backtrack.lua](06_backtrack.lua) | `Backtrack` : per-seq KV snapshot, `checkpoint`, `forward`, `constrain`, `run`, `backward` | Yes | ★★★★ |
| [07_dccd.lua](07_dccd.lua) | `DCCD` : draft pass, KV injection, constrained pass, `best_of(k)`, streaming | Yes | ★★★★ |
| [08_sql_agent.lua](08_sql_agent.lua) | Complete app : dynamic schema grammar, SQL hallucination prevention | Yes | ★★★★ |
| [09_abnf_rfc.lua](09_abnf_rfc.lua) | `from_abnf` driving RFC 3339 (date-time) and a RFC 3986 URI subset verbatim | No | ★★☆☆ |
| [10_ebnf_lang.lua](10_ebnf_lang.lua) | `from_ebnf` for an arithmetic DSL + minimal JSON, `from_auto` ergonomics | No | ★★☆☆ |

## What each example shows

**01 — Basics.** Every constructor. Run this first to see what GBNF looks like for each grammar type.

**02 — Composition.** Grammars compose like sets. All operators return `Grammar_obj` and chain freely.

**03 — Dynamic grammars.** Build grammars from your actual DB schema, tool registry, or known valid values. The model becomes physically incapable of hallucinating names that do not exist.

**04 — Fuzz & debug.** Validate grammars before touching the GPU. `fuzz_validate` catches over-constrained grammars, empty outputs, and compiler bugs in seconds.

**05 — With model.** The full workflow. Grammar pre-validation, `kv_clear`, sampler lifecycle, `GrammarContext` across turns.

**06 — Backtrack.** Step-level semantic validation with per-`seq_id` KV cache rollback — multi-tenant safe, drops into ion7-llm's `Pool` without disturbing other sessions. For SQL, entity extraction, any task where grammar validity alone is not enough.

**07 — DCCD.** Draft-Conditioned Constrained Decoding. The model generates a free-form "plan" (draft), then is constrained to grammar-valid output while attending to that plan. Reduces the projection tax of grammar masking. Use `best_of(k)` to rank multiple drafts.

**08 — SQL agent.** A complete real-world application combining dynamic grammars, `GrammarContext`, and the full pipeline to prevent SQL hallucination at the schema level.

**09 — ABNF RFC.** Drops a verbatim RFC 3339 date-time slice and a subset of RFC 3986 URI through `Grammar.from_abnf`. Demonstrates that grammars taken straight out of an IETF spec compile, fuzz, and describe a usable shape.

**10 — EBNF DSL.** Builds an arithmetic expression grammar and a minimal JSON grammar in W3C-style EBNF (the dialect XML / SVG / XPath specs use). Closes with `from_auto` showing that ion7-grammar routes the same string to the right constructor when the format is unknown ahead of time.

## What's not here yet

- `ion7-llm` integration end-to-end — chat orchestration, streaming helpers, multi-session pool with grammar samplers (covered by ion7-llm's [`05_grammar.lua`](https://github.com/Ion7-Labs/ion7-llm/blob/main/examples/05_grammar.lua)).
- RAG pipeline with grammar-constrained answer extraction.
