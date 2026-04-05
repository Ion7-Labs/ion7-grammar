# ion7-grammar examples

Progressive examples from minimal to advanced. Each runs standalone.

## Setup

```bash
# No model required for examples 01–04
cd /path/to/ion7-grammar

# With model (examples 05–08)
export ION7_MODEL=/path/to/model.gguf
export ION7_CORE=/path/to/ion7-core   # default: ../ion7-core
```

Run from the **project root**:

```bash
luajit examples/01_basics.lua
```

## Examples

| File | Concepts | Model | Difficulty |
|------|----------|-------|------------|
| [01_basics.lua](01_basics.lua) | `from_enum`, `from_regex`, `from_type`, `from_json_schema`, `from_builder`, `raw` | No | ★☆☆☆ |
| [02_composition.lua](02_composition.lua) | `union`, `sequence`, `wrap`, `interleave`, `repeat_g`, `optional`, `annotate`, `merge` | No | ★★☆☆ |
| [03_dynamic.lua](03_dynamic.lua) | `from_enum` with runtime data, `from_tools`, `GrammarContext`, snapshot/restore | No | ★★☆☆ |
| [04_fuzz_and_debug.lua](04_fuzz_and_debug.lua) | `fuzz`, `fuzz_one`, `fuzz_validate`, `debug`, `analyze`, `tree`, `diff` | No | ★★☆☆ |
| [05_with_model.lua](05_with_model.lua) | Full pipeline: build → fuzz-validate → constrain sampler → generate | Yes | ★★★☆ |
| [06_backtrack.lua](06_backtrack.lua) | `Backtrack`: KV snapshot, `checkpoint`, `forward`, `constrain`, `run`, `backward` | Yes | ★★★★ |
| [07_dccd.lua](07_dccd.lua) | `DCCD`: draft pass, KV injection, constrained pass, `best_of(k)`, streaming | Yes | ★★★★ |
| [08_sql_agent.lua](08_sql_agent.lua) | Complete app: dynamic schema grammar, SQL hallucination prevention | Yes | ★★★★ |

## What each example shows

**01 - Basics**: every constructor. Run this first to see what GBNF looks like for each grammar type.

**02 - Composition**: grammars compose like sets. All operators return `Grammar_obj` and chain freely.

**03 - Dynamic grammars**: the key feature for production systems. Build grammars from your actual DB schema, tool registry, or known valid values. The model becomes physically incapable of hallucinating names that don't exist.

**04 - Fuzz & debug**: validate grammars before touching the GPU. `fuzz_validate` catches over-constrained grammars, empty outputs, and compiler bugs in seconds.

**05 - With model**: the full workflow. Grammar pre-validation, `kv_clear`, sampler lifecycle, `GrammarContext` across turns.

**06 - Backtrack**: step-level semantic validation with KV cache rollback. Only the bad fragment is resampled - the rest of the context is unchanged. For SQL, entity extraction, any task where grammar validity alone is not enough.

**07 - DCCD**: draft-conditioned constrained decoding. The model generates a free-form "plan" (draft), then is constrained to grammar-valid output while attending to that plan. Reduces the projection tax of grammar masking. Use `best_of(k)` to rank multiple drafts.

**08 - SQL agent**: a complete real-world application combining dynamic grammars, `GrammarContext`, and the full pipeline to prevent SQL hallucination at the schema level.

## What's not here yet

- `ion7-llm` integration - chat management, stop strings, streaming helpers
- RAG pipeline with grammar-constrained answer extraction
