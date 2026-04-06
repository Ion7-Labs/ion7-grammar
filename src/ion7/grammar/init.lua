--- @module ion7.grammar
--- SPDX-License-Identifier: MIT
--- ion7-grammar - Best-in-class GBNF grammar engine for LuaJIT.
---
--- Pure Lua. Zero C. Works with any GGUF model via ion7-core.
--- Every public function returns a Grammar_obj - fully composable.
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast_m      = require "ion7.grammar.ast"
local Builder    = require "ion7.grammar.builder"
local regex_m    = require "ion7.grammar.regex"
local json_m     = require "ion7.grammar.json"
local Backtrack  = require "ion7.grammar.backtrack"
local Dynamic    = require "ion7.grammar.dynamic"
local Compose    = require "ion7.grammar.compose"
local Types      = require "ion7.grammar.types"
local Fuzzer     = require "ion7.grammar.fuzz"
local GrammarCtx = require "ion7.grammar.context"
local DCCD_m     = require "ion7.grammar.dccd"
local Debug_m    = require "ion7.grammar.debug"
local Except_m   = require "ion7.grammar.except"

-- ── Grammar_obj ───────────────────────────────────────────────────────────────
-- Every public constructor returns a Grammar_obj.
-- Grammar_obj is the single composable type in ion7-grammar.

--- @class Grammar_obj
--- @field _builder any  Underlying Builder (nil for raw grammars created via Grammar.raw()).
local Grammar_obj = {}
Grammar_obj.__index = Grammar_obj

--- @private
function Grammar_obj._new(b)
    assert(b, "[ion7.grammar] Grammar_obj._new: builder required")
    return setmetatable({ _builder = b }, Grammar_obj)
end

--- Compile to GBNF string ready for llama.cpp.
--- @param  root  string?  Override root rule name.
--- @return string
function Grammar_obj:to_gbnf(root)
    if root then self._builder:root(root) end
    return self._builder:compile()
end

--- Return the underlying Builder for manual rule manipulation.
--- @return Builder
function Grammar_obj:builder()
    return self._builder
end

--- Merge rules from another Grammar_obj into this one.
--- Rules from other are added only if not already defined in self.
--- Returns self (fluent, composable).
--- @param  other  Grammar_obj
--- @return Grammar_obj  self
function Grammar_obj:merge(other)
    local ob = type(other) == "table" and (other._builder or other) or other
    self._builder:merge(ob)
    return self
end

--- List all defined rule names in definition order.
--- @return table  Array of strings.
function Grammar_obj:rules()
    return self._builder:names()
end

--- Compose: match either this grammar or another (union).
--- Returns a new Grammar_obj.
--- @param  other  Grammar_obj
--- @return Grammar_obj
function Grammar_obj:union(other)
    return Grammar.union(self, other)
end

--- Compose: match this grammar followed by another (sequence).
--- @param  other  Grammar_obj
--- @param  sep    any?    Optional separator AST node (e.g. Grammar.literal(",")).
--- @return Grammar_obj
function Grammar_obj:then_(other, sep)
    return Grammar.sequence(self, other, sep and { separator = sep } or nil)
end

--- Fuzz: generate random valid strings from this grammar.
--- @param  opts  table?  { count, seed, max_rep, max_depth }
--- @return table   samples  Array of generated strings.
--- @return number  seed     RNG seed used (for reproduction).
function Grammar_obj:fuzz(opts)
    return Fuzzer.fuzz(self, opts)
end

--- Debug: return annotated GBNF with rule stats.
--- @return string
function Grammar_obj:inspect()
    return Debug_m.inspect(self)
end

-- ── Module ────────────────────────────────────────────────────────────────────

--- @class Grammar  Top-level namespace table returned by `require "ion7.grammar"`.
Grammar = {
    _VERSION  = "0.1.0",
    -- Sub-modules (direct access when needed)
    Backtrack = Backtrack,
    Dynamic   = Dynamic,
    Compose   = Compose,
    Types     = Types,
    Fuzzer    = Fuzzer,
    Context   = GrammarCtx,
    DCCD      = DCCD_m,
    Debug     = Debug_m,
    Except    = Except_m,
    -- JSON null sentinel
    null      = json_m.null,
}

-- ── AST primitives ────────────────────────────────────────────────────────────
-- Re-exported for ergonomic builder usage without requiring ion7.grammar.ast

Grammar.literal  = ast_m.literal  --- Exact string literal node.
Grammar.char     = ast_m.char     --- Character class node.
Grammar.ref      = ast_m.ref      --- Reference to a named rule.
Grammar.seq      = ast_m.seq      --- Sequence (all must match in order).
Grammar.alt      = ast_m.alt      --- Alternation (first match wins).
Grammar.rep      = ast_m.rep      --- Repetition with bounds.
Grammar.star     = ast_m.star     --- Zero or more.
Grammar.plus     = ast_m.plus     --- One or more.
Grammar.opt      = ast_m.opt      --- Zero or one (optional).
Grammar.exactly  = ast_m.exactly  --- Exactly N times.
Grammar.group    = ast_m.group    --- Grouping.
-- Common char class shortcuts
Grammar.DIGIT    = ast_m.DIGIT    --- [0-9]
Grammar.ALPHA    = ast_m.ALPHA    --- [a-zA-Z]
Grammar.ALNUM    = ast_m.ALNUM    --- [a-zA-Z0-9]
Grammar.SPACE    = ast_m.SPACE    --- [ \t\n\r]
Grammar.WS       = ast_m.WS       --- optional whitespace

-- ── Constructors (all return Grammar_obj) ─────────────────────────────────────

--- Create a new GrammarBuilder (returns Builder, not Grammar_obj).
--- Use when you need fine-grained rule control.
--- @param  opts  table?  { root = "root" }
--- @return Builder
function Grammar.builder(opts)
    return Builder.new(opts)
end

--- Wrap a Builder in a Grammar_obj.
--- @param  b  Builder
--- @return Grammar_obj
function Grammar.from_builder(b)
    return Grammar_obj._new(b)
end

--- Build from JSON Schema (draft-07 subset).
--- @param  schema  table   JSON Schema.
--- @param  root    string? Root rule (default: "root").
--- @return Grammar_obj
function Grammar.from_json_schema(schema, root)
    root = root or "root"
    local rules, root_name = json_m.to_rules(schema, root)
    local b = Builder.new({ root = root_name })
    for _, r in ipairs(rules) do b:rule(r.name, r.body) end
    return Grammar_obj._new(b)
end

--- Build from Lua type annotation (shortest path to a grammar).
---
--- Syntax: "string"|"integer"|"number"|"boolean"|"null"|"any"
---   "type?"      → optional (null|type)
---   {"type"}     → array of that type
---   {key="type"} → object (all required)
---   {["key?"]="type"} → optional field
---
--- @param  typ   string|table
--- @param  root  string?
--- @return Grammar_obj
function Grammar.from_type(typ, root)
    return Types.from_type(typ, root)
end

--- Build from regex pattern (ERE subset).
--- @param  pattern  string
--- @param  root     string?
--- @return Grammar_obj
function Grammar.from_regex(pattern, root)
    root = root or "root"
    local b = Builder.new({ root = root })
    b:rule(root, regex_m.to_ast(pattern))
    return Grammar_obj._new(b)
end

--- Build from value whitelist (input-dependent, longest-first).
--- @param  rule_name  string
--- @param  values     table
--- @return Grammar_obj
function Grammar.from_enum(rule_name, values)
    return Grammar_obj._new(Dynamic.from_enum(rule_name, values))
end

--- Build from JSON-quoted value whitelist.
--- @param  rule_name  string
--- @param  values     table
--- @return Grammar_obj
function Grammar.from_json_enum(rule_name, values)
    return Grammar_obj._new(Dynamic.from_json_enum(rule_name, values))
end

--- Build tool-call grammar from registry.
--- @param  tools  table  Array of { name, schema }.
--- @return Grammar_obj
function Grammar.from_tools(tools)
    return Grammar_obj._new(Dynamic.from_tools(tools))
end

--- Passthrough for hand-written GBNF strings.
--- @param  gbnf  string
--- @return Grammar_obj
function Grammar.raw(gbnf)
    local obj = setmetatable({}, Grammar_obj)
    obj._builder = nil
    obj.to_gbnf  = function() return gbnf end
    obj.builder  = function() error("[ion7.grammar] raw grammar has no builder") end
    obj.merge    = function() error("[ion7.grammar] raw grammar cannot be merged") end
    obj.rules    = function() return {} end
    obj.fuzz     = function() error("[ion7.grammar] raw grammar cannot be fuzzed") end
    obj.inspect  = function() return gbnf end
    return obj
end

-- ── Composition (all return Grammar_obj) ─────────────────────────────────────

--- Union: match either grammar a or b.
--- @param  a  Grammar_obj
--- @param  b  Grammar_obj
--- @return Grammar_obj
function Grammar.union(a, b)
    return Grammar_obj._new(Compose.union(a, b))
end

--- Sequence: match grammar a followed by b.
--- @param  a    Grammar_obj
--- @param  b    Grammar_obj
--- @param  opts table?  { separator = node? }
--- @return Grammar_obj
function Grammar.sequence(a, b, opts)
    return Grammar_obj._new(Compose.sequence(a, b, opts))
end

--- Wrap grammar with prefix and suffix literals.
--- @param  g    Grammar_obj
--- @param  pre  string
--- @param  suf  string
--- @param  ws   boolean?  Insert whitespace padding (default: true).
--- @return Grammar_obj
function Grammar.wrap(g, pre, suf, ws)
    return Grammar_obj._new(Compose.wrap(g, pre, suf, ws))
end

--- Match grammar g with separator between elements.
--- @param  g    Grammar_obj
--- @param  sep  string  Separator literal.
--- @param  min  number?  Min elements (default: 1).
--- @param  max  number?  Max elements (default: unlimited).
--- @return Grammar_obj
function Grammar.interleave(g, sep, min, max)
    return Grammar_obj._new(Compose.interleave(g, sep, min, max))
end

--- Repeat grammar g between min and max times.
--- @param  g    Grammar_obj
--- @param  min  number?
--- @param  max  number?
--- @param  sep  any?    Optional separator AST node placed between repetitions.
--- @return Grammar_obj
function Grammar.repeat_g(g, min, max, sep)
    return Grammar_obj._new(Compose.repeat_g(g, min, max, sep))
end

--- Make grammar optional.
--- @param  g  Grammar_obj
--- @return Grammar_obj
function Grammar.optional(g)
    return Grammar_obj._new(Compose.optional(g))
end

--- Annotate: rename the root rule.
--- @param  g     Grammar_obj
--- @param  name  string
--- @return Grammar_obj
function Grammar.annotate(g, name)
    return Grammar_obj._new(Compose.annotate(g, name))
end

-- ── Fuzzer ────────────────────────────────────────────────────────────────────

--- Generate random valid strings (zero LLM, instant).
--- @param  g     Grammar_obj
--- @param  opts  table?  { count, seed, max_rep, max_depth, root }
--- @return table   samples  Array of generated strings.
--- @return number  seed     RNG seed used (for reproduction).
function Grammar.fuzz(g, opts)
    return Fuzzer.fuzz(g, opts)
end

--- Generate one random valid string.
--- @param  g     Grammar_obj
--- @param  opts  table?
--- @return string
function Grammar.fuzz_one(g, opts)
    return Fuzzer.one(g, opts)
end

--- Validate grammar produces non-empty strings.
--- @param  g     Grammar_obj
--- @param  opts  table?
--- @return boolean  ok   true if grammar produces valid non-empty output.
--- @return string?  err  Error description if ok is false, otherwise nil.
function Grammar.fuzz_validate(g, opts)
    return Fuzzer.validate(g, opts)
end

-- ── Context ───────────────────────────────────────────────────────────────────

--- Create a stateful GrammarContext (evolves with conversation).
--- @param  opts  table?  { root = "root" }
--- @return any  GrammarContext instance (see ion7.grammar.context).
function Grammar.context(opts)
    return GrammarCtx.new(opts)
end

-- ── Backtracking ──────────────────────────────────────────────────────────────

--- Create a Backtrack session (IterGen/CRANE style, KV cache rollback).
--- @param  ctx      any     ion7-core Context (snapshot support required).
--- @param  vocab    any     ion7-core Vocab.
--- @param  sampler  any     ion7-core Sampler (grammar-constrained).
--- @param  opts     table?
--- @return any  Backtrack instance (see ion7.grammar.backtrack).
function Grammar.backtrack(ctx, vocab, sampler, opts)
    return Backtrack.new(ctx, vocab, sampler, opts)
end

-- ── DCCD ─────────────────────────────────────────────────────────────────────

--- Draft-Conditioned Constrained Decoding (arXiv:2603.03305, Feb 2026).
--- @param  ctx    any    ion7-core Context (snapshot support required).
--- @param  vocab  any    ion7-core Vocab.
--- @param  opts   table  { draft_sampler, constrain_sampler, max_draft_tokens, max_final_tokens, ... }
--- @return any  DCCD instance (see ion7.grammar.dccd).
function Grammar.dccd(ctx, vocab, opts)
    return DCCD_m.new(ctx, vocab, opts)
end

-- ── Debug ─────────────────────────────────────────────────────────────────────

--- Pretty-print grammar with rule stats.
--- @param  g     Grammar_obj
--- @param  opts  table?
--- @return string
function Grammar.debug(g, opts)
    return Debug_m.inspect(g, opts)
end

--- Structural analysis of a grammar.
--- @param  g  Grammar_obj
--- @return table  { n_rules, root, unreferenced, recursive, gbnf_length }
function Grammar.analyze(g)
    return Debug_m.analyze(g)
end

--- ASCII dependency tree of rule references.
--- @param  g  Grammar_obj
--- @return string
function Grammar.tree(g)
    return Debug_m.tree(g)
end

--- Diff two grammars: show added/removed/changed rules.
--- @param  g1  Grammar_obj  Original.
--- @param  g2  Grammar_obj  Updated.
--- @return string
function Grammar.diff(g1, g2)
    return Debug_m.diff(g1, g2)
end

-- ── Except ────────────────────────────────────────────────────────────────────

--- Exclude chars from a class. Returns an AST node (use in builders).
--- @param  base_spec  string
--- @param  exclude    table
--- @return any  AST char node suitable for use with Grammar.builder():rule().
function Grammar.except_chars(base_spec, exclude)
    return Except_m.except_chars(base_spec, exclude)
end

--- Match any value from universe except excluded ones.
--- @param  universe  table
--- @param  exclude   table
--- @param  name      string?
--- @return Grammar_obj
function Grammar.except_values(universe, exclude, name)
    return Grammar_obj._new(Except_m.except_values(universe, exclude, name))
end

--- Lua pattern validator for Backtrack:constrain() (rejects matches).
--- @param  pattern  string
--- @return function
function Grammar.except_pattern(pattern)
    return Except_m.except_pattern(pattern)
end

return Grammar
