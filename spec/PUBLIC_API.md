# ion7-grammar - Public API Contract v0.1

> **Stability**: all symbols listed here are stable across patch versions.
> Breaking changes require a minor version bump (0.2).

---

## Overview

```lua
local Grammar = require "ion7.grammar"
```

Every public constructor returns a `Grammar_obj`. All `Grammar_obj`s are
composable via the composition operators. Sub-modules are accessible via
`Grammar.Compose`, `Grammar.Fuzzer`, etc. for advanced use.

---

## 1. Grammar constructors

All return `Grammar_obj` unless noted.

### Grammar.from_json_schema(schema, root?)

Build a grammar from a JSON Schema (draft-07 subset).

| Parameter | Type | Description |
|-----------|------|-------------|
| `schema` | `table` | JSON Schema as a Lua table |
| `root` | `string?` | Root rule name (default: `"root"`) |

Returns: `Grammar_obj`

Supported keywords: `type`, `properties`, `required`, `additionalProperties`,
`items`, `minItems`, `maxItems`, `enum`, `const`, `oneOf`, `anyOf`, `allOf`
(shallow merge, best-effort), `$ref` (local only), `$defs`, `definitions`,
`minLength`, `maxLength`, `pattern` (via regex module).
`minimum`/`maximum` are NOT expressible in GBNF and are ignored.

```lua
local g = Grammar.from_json_schema({
    type = "object",
    properties = {
        name = { type = "string" },
        age  = { type = "integer" },
    },
    required = { "name" },
})
```

---

### Grammar.from_type(annotation, root?)

Shortest path to a grammar: Lua type annotations -> GBNF. No JSON Schema knowledge required.

| Parameter | Type | Description |
|-----------|------|-------------|
| `annotation` | `string\|table` | Type annotation in ion7 type syntax |
| `root` | `string?` | Root rule name (default: `"root"`) |

Returns: `Grammar_obj`

**Type annotation syntax:**

| Annotation | JSON Schema equivalent |
|------------|------------------------|
| `"string"` | `{ type = "string" }` |
| `"integer"` | `{ type = "integer" }` |
| `"number"` | `{ type = "number" }` |
| `"boolean"` | `{ type = "boolean" }` |
| `"null"` | `{ type = "null" }` |
| `"any"` | unconstrained |
| `"T?"` | optional: `null \| T` |
| `{ "T" }` | array of type T |
| `{ key = "T", ... }` | object with required fields |
| `{ ["key?"] = "T" }` | object with optional field |

```lua
local g = Grammar.from_type({
    name       = "string",
    age        = "integer",
    ["score?"] = "number",   -- optional field
    tags       = { "string" },
})
```

---

### Grammar.from_regex(pattern, root?)

Build a grammar from a regex pattern (ERE subset).

| Parameter | Type | Description |
|-----------|------|-------------|
| `pattern` | `string` | ERE/PCRE subset regex pattern |
| `root` | `string?` | Root rule name (default: `"root"`) |

Returns: `Grammar_obj`

Supported: `.`, `[abc]`, `[^abc]`, `[a-z]`, `\d \w \s` (and `\D \W \S`),
`\n \r \t`, `* + ?`, `{n}`, `{n,m}`, `{n,}`, `(group)`, `(?:group)`, `a|b`.
`^` and `$` anchors are no-ops (GBNF has no positional concept).
Lookaheads, lookbehinds, and backreferences are not supported.

```lua
local g = Grammar.from_regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")  -- ISO date
```

---

### Grammar.from_enum(rule_name, values)

Build from a string whitelist. Values sorted longest-first to prevent prefix ambiguity.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rule_name` | `string` | Name for the generated GBNF rule |
| `values` | `table` | Non-empty array of allowed string values |

Returns: `Grammar_obj`

Errors if `values` is empty.

```lua
local g = Grammar.from_enum("root", { "GET", "POST", "PUT", "DELETE" })
```

---

### Grammar.from_json_enum(rule_name, values)

Like `from_enum` but wraps each value in JSON string quotes. Use for JSON field values.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rule_name` | `string` | Name for the generated GBNF rule |
| `values` | `table` | Non-empty array of unquoted string values |

Returns: `Grammar_obj`

Values are JSON-escaped (backslashes and double-quotes handled automatically).

```lua
local g = Grammar.from_json_enum("root", { "ok", "error", "pending" })
-- model must emit: "ok" or "error" or "pending"  (with quotes)
```

---

### Grammar.from_tools(tools)

Build a tool-call grammar from a registry of tool definitions.

| Parameter | Type | Description |
|-----------|------|-------------|
| `tools` | `table` | Non-empty array of `{ name, schema? }` tables |

Returns: `Grammar_obj`

Each tool produces a `tool-<name>` rule matching:
`{"name":"<tool_name>","arguments":{...schema...}}`.
All tools are combined in an alternation under a `tool-call` root rule.
A `root` alias pointing to `tool-call` is also added.

```lua
local g = Grammar.from_tools({
    { name = "search-web",
      schema = { type = "object",
          properties = { query = { type = "string" } },
          required   = { "query" } } },
    { name = "read-file",
      schema = { type = "object",
          properties = { path = { type = "string" } },
          required   = { "path" } } },
})
```

---

### Grammar.raw(gbnf)

Passthrough for hand-written GBNF strings. No builder. No composition.

| Parameter | Type | Description |
|-----------|------|-------------|
| `gbnf` | `string` | Hand-written GBNF string |

Returns: `Grammar_obj` (restricted: `builder()`, `merge()`, `fuzz()` error on call)

```lua
local g = Grammar.raw('root ::= "yes" | "no" | "maybe"\n')
```

---

### Grammar.builder(opts?)

Create a new `Builder` for fine-grained rule control. Returns a `Builder`, not a `Grammar_obj`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `opts` | `table?` | `{ root = "root" }` root rule name |

Returns: `Builder`

Use `Grammar.from_builder(b)` to wrap in a `Grammar_obj`.

---

### Grammar.from_builder(b)

Wrap a `Builder` in a `Grammar_obj`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `b` | `Builder` | Builder to wrap |

Returns: `Grammar_obj`

```lua
local b = Grammar.builder()
    :rule("root", Grammar.plus(Grammar.DIGIT))
local g = Grammar.from_builder(b)
```

---

## 2. Grammar_obj methods

The single composable type. Every public constructor returns one.

### g:to_gbnf(root?)

Compile to GBNF string ready for llama.cpp.

| Parameter | Type | Description |
|-----------|------|-------------|
| `root` | `string?` | Override root rule name for this compilation |

Returns: `string` - GBNF grammar string

```lua
local gbnf = grammar:to_gbnf()
-- Pass to: ion7.Sampler.chain():grammar(gbnf, "root", vocab):build(vocab)
```

---

### g:builder()

Return the underlying `Builder` for manual rule inspection or manipulation.

Returns: `Builder`

Note: errors on `Grammar.raw()` grammars.

---

### g:merge(other)

Merge rules from `other` into this grammar. Rules from `other` are added only if
not already defined in `self`. Fluent - returns `self`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `other` | `Grammar_obj` | Grammar whose rules to import |

Returns: `Grammar_obj` (self)

Note: errors on `Grammar.raw()` grammars.

---

### g:rules()

List all defined rule names in definition order.

Returns: `table` - array of rule name strings

---

### g:union(other)

Match either this grammar or `other`. Shorthand for `Grammar.union(self, other)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `other` | `Grammar_obj` | Alternative grammar |

Returns: `Grammar_obj` (new)

---

### g:then_(other, sep?)

Match this grammar followed by `other`. Shorthand for `Grammar.sequence(self, other, ...)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `other` | `Grammar_obj` | Grammar to append |
| `sep` | `any?` | Optional AST separator node placed between (e.g. `Grammar.literal(",")`) |

Returns: `Grammar_obj` (new)

---

### g:fuzz(opts?)

Generate random valid strings from this grammar without a model.

| Parameter | Type | Description |
|-----------|------|-------------|
| `opts` | `table?` | `{ count, seed, max_rep, max_depth }` |

Returns: `table` (array of strings), `number` (seed used)

Note: errors on `Grammar.raw()` grammars.

---

### g:inspect()

Return annotated GBNF with rule statistics. Alias for `Grammar.debug(self)`.

Returns: `string` - multi-line human-readable representation

---

## 3. Composition

All composition operators return `Grammar_obj`. Rules from input grammars are
namespaced with `"a-"` and `"b-"` prefixes to prevent name collisions.

### Grammar.union(a, b)

Match either grammar `a` or grammar `b`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `a` | `Grammar_obj` | First alternative |
| `b` | `Grammar_obj` | Second alternative |

Returns: `Grammar_obj`

---

### Grammar.sequence(a, b, opts?)

Match grammar `a` followed immediately by grammar `b`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `a` | `Grammar_obj` | First grammar |
| `b` | `Grammar_obj` | Second grammar |
| `opts` | `table?` | `{ separator = node? }` - AST node placed between a and b |

Returns: `Grammar_obj`

---

### Grammar.wrap(g, pre, suf, ws?)

Surround grammar `g` with prefix and suffix literals.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to wrap |
| `pre` | `string` | Prefix literal (e.g. `"["`) |
| `suf` | `string` | Suffix literal (e.g. `"]"`) |
| `ws` | `boolean?` | Insert optional whitespace between delimiters (default: `true`) |

Returns: `Grammar_obj`

---

### Grammar.interleave(g, sep, min?, max?)

Match grammar `g` with `sep` between each element: `g (sep g)*`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Repeated grammar |
| `sep` | `string\|table` | Separator: literal string or AST node |
| `min` | `number?` | Minimum elements (default: `1`) |
| `max` | `number?` | Maximum elements (default: `-1` = unlimited) |

Returns: `Grammar_obj`

---

### Grammar.repeat_g(g, min?, max?, sep?)

Repeat grammar `g` between `min` and `max` times.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to repeat |
| `min` | `number?` | Minimum repetitions (default: `0`) |
| `max` | `number?` | Maximum repetitions (default: `-1` = unlimited) |
| `sep` | `any?` | Optional AST separator node placed between repetitions |

Returns: `Grammar_obj`

---

### Grammar.optional(g)

Match grammar `g` or the empty string (zero or one occurrence).

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to make optional |

Returns: `Grammar_obj`

---

### Grammar.annotate(g, name)

Rename the root rule of a grammar. Useful when embedding into larger compositions.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to annotate |
| `name` | `string` | New root rule name |

Returns: `Grammar_obj`

---

## 4. AST primitives

For use inside `Builder:rule(name, body)`. All functions return AST nodes.

```lua
local Grammar = require "ion7.grammar"
-- or: local ast = require "ion7.grammar.ast"
```

### Grammar.literal(s)

Exact string literal.

| Parameter | Type | Description |
|-----------|------|-------------|
| `s` | `string` | The literal text to match exactly |

Returns: `node` - `{ kind="literal", value=s }`

---

### Grammar.char(spec, negated?)

Character class node.

| Parameter | Type | Description |
|-----------|------|-------------|
| `spec` | `string` | Character class spec, e.g. `"a-zA-Z0-9_"` or `"\\n\\t"` |
| `negated` | `bool?` | When true the class is negated: `[^spec]` (default: false) |

Returns: `node` - `{ kind="char", spec=spec, negated=negated }`

---

### Grammar.ref(name)

Reference to a named rule.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Rule name to reference |

Returns: `node` - `{ kind="ref", name=name }`

---

### Grammar.seq(...)

Sequence: all nodes must match in left-to-right order.

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | `node` | One or more AST nodes |

Returns: `node` - `{ kind="seq", items={...} }`, or the single node if only one argument.

---

### Grammar.alt(...)

Alternation: first matching alternative wins (ordered choice).

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | `node` | One or more AST nodes |

Returns: `node` - `{ kind="alt", items={...} }`, or the single node if only one argument.

---

### Grammar.rep(node, min, max)

Repetition with explicit bounds.

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | `node` | The node to repeat |
| `min` | `number` | Minimum repetitions (0 = optional, default: 0) |
| `max` | `number` | Maximum repetitions (-1 = unlimited, default: -1) |

Returns: `node` - `{ kind="rep", node=node, min=min, max=max }`

---

### Grammar.star(node)

Zero or more repetitions (Kleene star). Equivalent to `Grammar.rep(node, 0, -1)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | `node` | The node to repeat |

Returns: `node`

---

### Grammar.plus(node)

One or more repetitions (Kleene plus). Equivalent to `Grammar.rep(node, 1, -1)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | `node` | The node to repeat |

Returns: `node`

---

### Grammar.opt(node)

Zero or one occurrence (optional). Equivalent to `Grammar.rep(node, 0, 1)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | `node` | The node to make optional |

Returns: `node`

---

### Grammar.exactly(node, n)

Exactly N repetitions. Equivalent to `Grammar.rep(node, n, n)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | `node` | The node to repeat |
| `n` | `number` | The exact repeat count |

Returns: `node`

---

### Grammar.group(node)

Explicit parenthesis grouping. Use when an `alt` or `seq` must be treated as a
single unit inside another `alt` or `rep`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | `node` | The node to wrap |

Returns: `node` - `{ kind="group", node=node }`

---

### Pre-built character class constants

| Constant | Matches |
|----------|---------|
| `Grammar.DIGIT` | `[0-9]` |
| `Grammar.ALPHA` | `[a-zA-Z]` |
| `Grammar.ALNUM` | `[a-zA-Z0-9]` |
| `Grammar.SPACE` | `[ \t\n]` |
| `Grammar.WS` | `[ \t\n]*` (optional whitespace - zero or more SPACE) |

Note: `Grammar.SPACE` matches a single whitespace character.
`Grammar.WS` is `star(SPACE)` - zero or more whitespace characters (an AST node, not a Grammar_obj).

---

## 5. Fuzzer

Generate random valid strings - zero LLM, zero GPU, instant. Use to validate
grammar correctness before passing to the model.

### Grammar.fuzz(g, opts?)

Generate random valid strings from grammar `g`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to fuzz |
| `opts` | `table?` | Options (see below) |

Options:

| Field | Default | Description |
|-------|---------|-------------|
| `count` | `5` | Number of strings to generate |
| `seed` | random | RNG seed for reproducibility |
| `max_depth` | `20` | Maximum recursion depth |
| `max_rep` | `4` | Maximum repetitions for `*` and `+` |
| `root` | `"root"` | Root rule name to start from |

Returns: `table` (array of generated strings), `number` (seed used)

Same seed always produces the same output (reproducible).

```lua
local samples, seed = Grammar.fuzz(g, { count = 5, seed = 42 })
```

---

### Grammar.fuzz_one(g, opts?)

Generate exactly one random valid string. Convenience wrapper around `fuzz()`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to fuzz |
| `opts` | `table?` | Same as `fuzz()` (count is ignored) |

Returns: `string`

---

### Grammar.fuzz_validate(g, opts?)

Validate that a grammar produces non-empty valid strings. Use before every model call.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to validate |
| `opts` | `table?` | Same as `fuzz()`, plus `allow_empty` (bool) |

Returns: `boolean` (`true` if valid), `string?` (error description if false, nil if true)

```lua
local ok, err = Grammar.fuzz_validate(g, { count = 20, seed = 1 })
if not ok then error("Grammar issue: " .. err) end
```

---

## 6. GrammarContext

Stateful grammar that evolves across conversation turns. The grammar is rebuilt
lazily (cached until the next `learn_*` or `forget()` call invalidates it).

### Grammar.context(opts?)

Create a new `GrammarContext`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `opts` | `table?` | `{ root = "root" }` default root rule name |

Returns: `GrammarContext`

---

### ctx:learn_enum(rule_name, values)

Register a string whitelist rule. Replaces any previously registered enum with the same name.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rule_name` | `string` | Rule name |
| `values` | `table` | Array of allowed string values |

Returns: `GrammarContext` (self, fluent)

---

### ctx:learn_table(name, columns)

Register a database table with its column names. Creates two rules: `<name>` (table
name) and `<name>-col` (column names). Also maintains combined `table-name` and
`column-name` enums across all registered tables.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Table name |
| `columns` | `table` | Array of column name strings |

Returns: `GrammarContext` (self, fluent)

---

### ctx:learn_tool(name, schema?)

Register a tool definition. Replaces any previously registered tool with the same name.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Tool name |
| `schema` | `table?` | JSON Schema for arguments (default: `{ type = "object" }`) |

Returns: `GrammarContext` (self, fluent)

---

### ctx:learn_rule(rule_name, body)

Add or replace a custom AST rule.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rule_name` | `string` | Rule name |
| `body` | `node` | AST node (from Grammar.seq, Grammar.alt, etc.) |

Returns: `GrammarContext` (self, fluent)

---

### ctx:forget(name)

Remove a learned rule, enum, table, or tool by name. Invalidates the cache.

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | `string` | Rule/table/tool name to remove |

Returns: `GrammarContext` (self, fluent)

---

### ctx:current()

Build and return the current `Grammar_obj` reflecting all learned knowledge.
Result is cached until a `learn_*` or `forget()` call invalidates it.

Returns: `Grammar_obj`

---

### ctx:snapshot()

Serialize the current state for later restoration. Deep-copies all learned enums,
tables, tools, and extra rules.

Returns: `table` - snapshot of current learned state

---

### ctx:restore(snap)

Restore state from a snapshot. Invalidates the cache.

| Parameter | Type | Description |
|-----------|------|-------------|
| `snap` | `table` | From `ctx:snapshot()` |

Returns: `GrammarContext` (self, fluent)

---

### ctx:stats()

Return a summary of what this context has learned.

Returns: `table` - `{ n_enums, n_tables, n_tools, n_extra }`

---

### ctx:to_gbnf(root?)

Compile the current grammar to GBNF. Shorthand for `ctx:current():to_gbnf(root)`.

Note: `to_gbnf` and `rules` are convenience methods available on the Grammar_obj
returned by `ctx:current()`, not directly on the GrammarContext itself.
Call `ctx:current()` to get the Grammar_obj, then call these on it.

---

### ctx:rules()

List rule names of the current compiled grammar. Shorthand for `ctx:current():rules()`.

Returns: `table` - array of rule name strings

---

## 7. Debug

### Grammar.debug(g, opts?)

Pretty-print grammar with rule statistics. Annotated GBNF showing ref counts.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to inspect |
| `opts` | `table?` | `{ show_stats = true, max_width = 80 }` |

Returns: `string` - multi-line human-readable representation

---

### Grammar.analyze(g)

Structural analysis of a grammar.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to analyze |

Returns: `table` - `{ n_rules, root, unreferenced, recursive, gbnf_length }`

| Field | Type | Description |
|-------|------|-------------|
| `n_rules` | `number` | Total rule count |
| `root` | `string` | Root rule name |
| `unreferenced` | `table` | Array of rule names not referenced by other rules |
| `recursive` | `table` | Array of self-recursive rule names |
| `gbnf_length` | `number` | GBNF string byte length |

---

### Grammar.tree(g)

ASCII dependency tree of rule references starting from root.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g` | `Grammar_obj` | Grammar to visualize |

Returns: `string` - ASCII tree

---

### Grammar.diff(g1, g2)

Diff two grammars: show added, removed, and changed rules.

| Parameter | Type | Description |
|-----------|------|-------------|
| `g1` | `Grammar_obj` | Original grammar |
| `g2` | `Grammar_obj` | Updated grammar |

Returns: `string` - diff-style output with `+` (added), `-` (removed), `~` (changed) lines

---

## 8. Except

Exclusion and complement operators. Character-level and value-level exclusions are
exact; pattern-based exclusions are approximate and require `Backtrack:constrain()`.

### Grammar.except_chars(base_spec, exclude)

Exclude specific characters from a character class. Returns an AST node, not a Grammar_obj.

| Parameter | Type | Description |
|-----------|------|-------------|
| `base_spec` | `string` | Base character class spec (e.g. `"a-zA-Z0-9"`) |
| `exclude` | `table` | Characters to exclude (e.g. `{"a","e","i","o","u"}`) |

Returns: `node` - AST char node for use inside `Builder:rule()`

Note: this returns an AST node, not a Grammar_obj. Wrap in a builder to use as a grammar.

```lua
local consonants = Grammar.except_chars("a-z", {"a","e","i","o","u"})
local g = Grammar.from_builder(Grammar.builder():rule("root", consonants))
```

---

### Grammar.except_values(universe, exclude, name?)

Match any value from `universe` except the values in `exclude`. Exact.

| Parameter | Type | Description |
|-----------|------|-------------|
| `universe` | `table` | All possible values (the full set) |
| `exclude` | `table` | Values to exclude |
| `name` | `string?` | Root rule name (default: `"except"`) |

Returns: `Grammar_obj`

Errors if no values remain after exclusion.

```lua
local safe = Grammar.except_values(
    { "GET", "POST", "PUT", "DELETE", "PATCH" },
    { "DELETE" },
    "root"
)
```

---

### Grammar.except_pattern(pattern)

Backtrack-based exclusion validator. Returns a validator function for use with
`Backtrack:constrain()` or `Backtrack:backward()`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `pattern` | `string` | Lua pattern string. Matching strings are rejected. |

Returns: `function` - `fn(text) -> bool` (`true` = accept, `false` = reject)

```lua
bt:constrain("field_name", Grammar.except_pattern("^_"))
```

---

## 9. DCCD

Draft-Conditioned Constrained Decoding (arXiv:2603.03305, Feb 2026).

Reduces the "projection tax" of grammar-constrained decoding by first generating
an unconstrained draft, then running constrained decoding on the context augmented
with that draft. Requires ion7-core for KV cache snapshot/restore.

### Grammar.dccd(ctx, vocab, opts)

Create a DCCD generator.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctx` | `any` | ion7-core Context (snapshot support required) |
| `vocab` | `any` | ion7-core Vocab |
| `opts` | `table` | Options (see below) |

Options:

| Field | Default | Description |
|-------|---------|-------------|
| `draft_sampler` | - | **(required)** Unconstrained sampler for step 1 |
| `constrain_sampler` | - | **(required)** Grammar-constrained sampler for step 2 |
| `max_draft_tokens` | `512` | Max tokens in draft pass |
| `max_final_tokens` | `512` | Max tokens in constrained pass |
| `on_draft_token` | `nil` | `function(piece)` called with each draft token piece |
| `on_final_token` | `nil` | `function(piece)` called with each constrained token piece |
| `best_of_k` | `1` | Generate K drafts, use best |

Returns: `DCCD` instance

---

### dc:generate(opts?)

Generate using Draft-Conditioned Constrained Decoding. The prompt must already be
decoded into `ctx` before calling (i.e. `ctx:decode(prompt_tokens)` called first).

**Context size requirement**: `n_ctx >= prompt_tokens + max_draft_tokens + max_final_tokens`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `opts` | `table?` | Override `max_draft_tokens`, `max_final_tokens`, `best_of_k` per call |

Returns: `table` - `{ text, draft, tokens, draft_tokens, stop_reason, n_tokens, n_draft_toks }`

| Field | Type | Description |
|-------|------|-------------|
| `text` | `string` | Final constrained output (guaranteed grammar-valid) |
| `draft` | `string` | The unconstrained draft (for debugging) |
| `tokens` | `table` | Final token ID array |
| `draft_tokens` | `table` | Draft token ID array |
| `stop_reason` | `string` | `"stop"` (EOG) or `"length"` |
| `n_tokens` | `number` | Final token count |
| `n_draft_toks` | `number` | Draft token count |

---

### dc:best_of(k, opts?)

Convenience: run DCCD with best-of-K draft selection. Equivalent to calling
`generate({ best_of_k = k, ... })`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `k` | `number` | Number of drafts to generate and rank |
| `opts` | `table?` | Same as `generate()` |

Returns: same as `dc:generate()`

**Note on best_of_k score approximation**: with `k > 1`, the best draft is
selected by the length of the constrained output - a proxy for the paper's
cumulative log feasible mass `S(k) = sum_t log(alpha_t)`. Exact `S(k)` requires
per-step logit access before grammar masking, which is not yet exposed by the
ion7-core sampler API (planned for v1.1). With `k=1` (the default), the
implementation is fully faithful to the paper.

---

## 10. Backtrack

Grammar-guided generation with KV cache rollback (IterGen/CRANE pattern).
Requires ion7-core for KV cache snapshot/restore.

### Grammar.backtrack(ctx, vocab, sampler, opts?)

Create a `Backtrack` session.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ctx` | `any` | ion7-core Context (snapshot support required) |
| `vocab` | `any` | ion7-core Vocab |
| `sampler` | `any` | ion7-core Sampler (grammar-constrained) |
| `opts` | `table?` | Options (see below) |

Options:

| Field | Default | Description |
|-------|---------|-------------|
| `max_tokens` | `2048` | Hard token budget for the entire session |
| `max_retries` | `10` | Max retries per `backward()` or `constrain()` call |
| `on_token` | `nil` | `function(piece)` called with each accepted token piece |

Returns: `Backtrack` instance

---

### bt:checkpoint(symbol)

Save a KV-cache snapshot at the current token position and associate it with a
symbol name. Call at logical grammar boundaries before generating each segment.

| Parameter | Type | Description |
|-----------|------|-------------|
| `symbol` | `string` | Symbol name (e.g. `"table_ref"`, `"field_name"`) |

Returns: `number` - token index of this checkpoint

---

### bt:forward(predicate?, max?)

Generate tokens until predicate returns true or max tokens reached.

| Parameter | Type | Description |
|-----------|------|-------------|
| `predicate` | `function?` | `fn(piece, all_text) -> bool` - return true to stop generating |
| `max` | `number?` | Override max tokens for this call |

Returns: `string` - all generated text so far (concatenated pieces)

---

### bt:backward(symbol, validator?)

Backtrack to the last checkpoint for `symbol` and resample one token.

| Parameter | Type | Description |
|-----------|------|-------------|
| `symbol` | `string` | Symbol name to rewind to |
| `validator` | `function?` | `fn(new_text) -> bool` - return true to accept, false to retry |

Returns: `boolean` - true if accepted, false if `max_retries` exhausted

Errors if no checkpoint exists for `symbol`.

---

### bt:constrain(symbol, validator, opts?)

Apply a semantic constraint at the current position (CRANE pattern). If the
constraint fails on the current text, backtracks to the last checkpoint of
`symbol` and resamples automatically.

| Parameter | Type | Description |
|-----------|------|-------------|
| `symbol` | `string` | Checkpoint symbol to backtrack to on failure |
| `validator` | `function` | `fn(text) -> bool` - true = satisfied, false = backtrack |
| `opts` | `table?` | `{ max_retries = number?, on_retry = function? }` |

Returns: `boolean` - true if constraint satisfied, false if retries exhausted

---

### bt:run(steps)

High-level loop combining `checkpoint()`, `forward()`, and `constrain()` for all steps.

| Parameter | Type | Description |
|-----------|------|-------------|
| `steps` | `table` | Array of step descriptors |

Each step descriptor:

| Field | Type | Description |
|-------|------|-------------|
| `symbol` | `string` | Checkpoint name |
| `until_pred` | `function?` | `fn(piece, text) -> bool` - stop forward when true |
| `validator` | `function?` | `fn(text) -> bool` - semantic constraint |
| `max_retries` | `number?` | Per-step retry limit override |

Returns: `string` (full generated text), `boolean` (true if all constraints satisfied)

---

### bt:text()

Return the full generated text so far.

Returns: `string`

---

### bt:is_done()

Return whether generation is complete.

Returns: `boolean` (true when EOG or max_tokens reached), `string?` (`"stop"` or `"length"`, or nil if not done)

---

### bt:n_tokens()

Number of tokens generated so far.

Returns: `number`

---

### bt:last_checkpoint(symbol)

Return the token index of the last checkpoint for a symbol, or nil if none.

| Parameter | Type | Description |
|-----------|------|-------------|
| `symbol` | `string` | Symbol name |

Returns: `number?` - token index, or nil if no checkpoint exists for this symbol

---

## Sub-module access

```lua
Grammar.Backtrack  -- Backtrack class
Grammar.Dynamic    -- input-dependent builders (from_enum, from_json_enum, from_tools, from_schema, from_values_with_pattern)
Grammar.Compose    -- composition operators (union, sequence, wrap, interleave, repeat_g, optional, annotate)
Grammar.Types      -- type annotation converters (from_type, to_schema)
Grammar.Fuzzer     -- fuzz, one, validate
Grammar.Context    -- GrammarContext class
Grammar.DCCD       -- DCCD class
Grammar.Debug      -- inspect, analyze, diff, tree
Grammar.Except     -- except_chars, except_values, except_prefix, except_pattern
Grammar.null       -- JSON null sentinel (use for const/enum encoding of JSON null)
```

---

## JSON Schema support (draft-07 subset)

| Keyword | Support |
|---------|---------|
| `type` (all 6) | yes |
| `properties` | yes |
| `required` | yes |
| `additionalProperties` | yes |
| `items` | yes |
| `minItems`, `maxItems` | yes |
| `enum` | yes |
| `const` | yes |
| `oneOf`, `anyOf` | yes (treated as alternation) |
| `allOf` | yes (shallow merge, best-effort) |
| `$ref` (local) | yes |
| `$defs`, `definitions` | yes |
| `minLength`, `maxLength` | yes |
| `pattern` | yes (via regex module) |
| `minimum`, `maximum` | no (not expressible in GBNF) |

---

## Regex support (ERE subset)

| Syntax | Support |
|--------|---------|
| `.` (any non-newline) | yes |
| `[abc]`, `[a-z]`, `[^abc]` | yes |
| `\d \w \s` (and `\D \W \S`) | yes |
| `\n \r \t` | yes |
| `*` `+` `?` | yes |
| `{n}` `{n,m}` `{n,}` | yes |
| `(group)` `(?:group)` | yes |
| `a\|b` alternation | yes |
| `^` `$` anchors | ignored (no-op in GBNF) |
| lookahead/lookbehind | no |
| backreferences | no |

---

## What is NOT guaranteed

- `allOf` intersection is approximated by shallow merge (last-write-wins on key conflicts)
- `minimum`/`maximum` on numbers are not expressible in GBNF and are silently ignored
- Regex anchors (`^` `$`) are no-ops - GBNF has no positional concept
- `Grammar.except_chars` and `Grammar.except_values` are exact; `Grammar.except_pattern` is approximate (requires Backtrack)
- DCCD `best_of_k > 1` uses output length as a proxy for the paper's cumulative log feasible mass (exact requires per-step logit access not yet exposed)
- `Grammar.raw()` grammars do not support `builder()`, `merge()`, or `fuzz()` - these error on call
