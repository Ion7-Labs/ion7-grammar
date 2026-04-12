--- SPDX-License-Identifier: MIT
--- ion7-grammar — Best-in-class GBNF grammar engine for LuaJIT.
---
--- Pure Lua. Zero C. Works with any GGUF model via ion7-core.
--- Every public constructor returns a Grammar_obj — fully composable.
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast_m    = require "ion7.grammar.ast"
local Builder  = require "ion7.grammar.ast.builder"
local regex_m  = require "ion7.grammar.from.regex"
local json_m   = require "ion7.grammar.from.json"
local Dynamic  = require "ion7.grammar.from.dynamic"
local Types    = require "ion7.grammar.from.types"
local Compose  = require "ion7.grammar.compose"
local Except_m = require "ion7.grammar.except"
local Fuzzer   = require "ion7.grammar.dev.fuzz"
local Debug_m  = require "ion7.grammar.dev.debug"

local go_mod   = require "ion7.grammar.grammar_obj"
local Grammar_obj = go_mod.Grammar_obj
local RawGrammar  = go_mod.RawGrammar

-- Lazy-loaded runtime modules (require ion7-core or are rarely used)
local function Backtrack()  return require "ion7.grammar.runtime.backtrack" end
local function GrammarCtx() return require "ion7.grammar.runtime.context"   end
local function DCCD_m()     return require "ion7.grammar.runtime.dccd"      end

-- ── Module ────────────────────────────────────────────────────────────────────

--- @class Grammar
local Grammar = {
    _VERSION  = "0.1.0",
    -- Sub-modules (direct access when needed)
    Compose   = Compose,
    Types     = Types,
    Fuzzer    = Fuzzer,
    Debug     = Debug_m,
    Except    = Except_m,
    Dynamic   = Dynamic,
    -- JSON null sentinel
    null      = json_m.null,
}

-- ── AST primitives (re-exported for ergonomic builder usage) ─────────────────

Grammar.literal  = ast_m.literal
Grammar.char     = ast_m.char
Grammar.ref      = ast_m.ref
Grammar.seq      = ast_m.seq
Grammar.alt      = ast_m.alt
Grammar.rep      = ast_m.rep
Grammar.star     = ast_m.star
Grammar.plus     = ast_m.plus
Grammar.opt      = ast_m.opt
Grammar.exactly  = ast_m.exactly
Grammar.group    = ast_m.group
Grammar.DIGIT    = ast_m.DIGIT
Grammar.ALPHA    = ast_m.ALPHA
Grammar.ALNUM    = ast_m.ALNUM
Grammar.SPACE    = ast_m.SPACE
Grammar.WS       = ast_m.WS

-- ── Builder access ────────────────────────────────────────────────────────────

--- Create a new Builder (returns Builder, not Grammar_obj).
--- @param  opts  table?  { root = "root" }
--- @return Builder
function Grammar.builder(opts)
    return Builder.new(opts)
end

--- Wrap a Builder in a Grammar_obj.
--- @param  b  Builder
--- @return Grammar_obj
function Grammar.from_builder(b)
    return Grammar_obj.new(b)
end

-- ── Constructors (all return Grammar_obj) ─────────────────────────────────────

--- Build from JSON Schema (draft-07 subset, pure Lua).
--- @param  schema  table
--- @param  root    string?
--- @return Grammar_obj
function Grammar.from_json_schema(schema, root)
    root = root or "root"
    local rules, root_name = json_m.to_rules(schema, root)
    local b = Builder.new({ root = root_name })
    for _, r in ipairs(rules) do b:rule(r.name, r.body) end
    return Grammar_obj.new(b)
end

--- Build from Lua type annotation (shortest path to a grammar).
--- @param  typ   string|table
--- @param  root  string?
--- @return Grammar_obj
function Grammar.from_type(typ, root)
    return Grammar_obj.new(Types.from_type(typ, root))
end

--- Build from regex pattern (ERE subset).
--- @param  pattern  string
--- @param  root     string?
--- @return Grammar_obj
function Grammar.from_regex(pattern, root)
    root = root or "root"
    local b = Builder.new({ root = root })
    b:rule(root, regex_m.to_ast(pattern))
    return Grammar_obj.new(b)
end

--- Build from value whitelist (longest-first, deduped).
--- @param  rule_name  string
--- @param  values     table
--- @return Grammar_obj
function Grammar.from_enum(rule_name, values)
    return Grammar_obj.new(Dynamic.from_enum(rule_name, values))
end

--- Build from JSON-quoted value whitelist.
--- @param  rule_name  string
--- @param  values     table
--- @return Grammar_obj
function Grammar.from_json_enum(rule_name, values)
    return Grammar_obj.new(Dynamic.from_json_enum(rule_name, values))
end

--- Build tool-call grammar from registry.
--- @param  tools  table  Array of { name, schema }.
--- @return Grammar_obj
function Grammar.from_tools(tools)
    return Grammar_obj.new(Dynamic.from_tools(tools))
end

--- Build from JSON Schema via the C++ libcommon backend (ion7-core required).
---
--- Prefer for schemas using $ref, allOf, anyOf, oneOf, or strict format
--- validators. Falls back to from_json_schema() if ion7-core is unavailable.
---
--- @param  schema  string|table
--- @param  root    string?
--- @return Grammar_obj
function Grammar.from_json_schema_native(schema, root)
    local schema_str
    if type(schema) == "table" then
        local json = require "ion7.vendor.json"
        schema_str = json.encode(schema)
    elseif type(schema) == "string" then
        schema_str = schema
    else
        error("[ion7.grammar] from_json_schema_native: schema must be a string or table")
    end

    local ok_loader, loader = pcall(require, "ion7.core.ffi.loader")
    if not ok_loader then
        local ok_j, json_dec = pcall(require, "ion7.vendor.json")
        local tbl = ok_j and json_dec.decode(schema_str) or schema
        return Grammar.from_json_schema(type(tbl) == "table" and tbl or schema, root)
    end

    local ffi = require "ffi"
    local B   = loader.instance().bridge
    local needed = B.ion7_json_schema_to_grammar(schema_str, #schema_str, nil, 0)
    if tonumber(needed) < 0 then
        error("[ion7.grammar] from_json_schema_native: invalid JSON schema")
    end
    local buf = ffi.new("char[?]", needed + 1)
    B.ion7_json_schema_to_grammar(schema_str, #schema_str, buf, needed + 1)
    return Grammar.raw(ffi.string(buf))
end

--- Build tool-call grammar AND return a bound JSON parser.
--- @param  tools  table
--- @return Grammar_obj
--- @return function  parser(raw_output) → calls, err
function Grammar.tool_pipeline(tools)
    local g = Grammar.from_tools(tools)
    local json_ok, json_mod = pcall(require, "ion7.vendor.json")

    local function parse(raw_output)
        if not json_ok then
            return nil, "[ion7.grammar] tool_pipeline parser requires ion7.vendor.json"
        end
        local ok, result = pcall(json_mod.decode, raw_output)
        if not ok then
            return nil, "json parse error: " .. tostring(result)
        end
        if type(result) == "table" and type(result.name) == "string" then
            return { result }
        end
        if type(result) == "table" then
            return result
        end
        return nil, "unexpected tool call format: " .. type(result)
    end

    return g, parse
end

--- Passthrough for hand-written GBNF strings.
--- @param  gbnf  string
--- @return Grammar_obj
function Grammar.raw(gbnf)
    return RawGrammar.new(gbnf)
end

-- ── Composition ───────────────────────────────────────────────────────────────

function Grammar.union(a, b)
    return Grammar_obj.new(Compose.union(a, b))
end

function Grammar.sequence(a, b, opts)
    return Grammar_obj.new(Compose.sequence(a, b, opts))
end

function Grammar.wrap(g, pre, suf, ws)
    return Grammar_obj.new(Compose.wrap(g, pre, suf, ws))
end

function Grammar.interleave(g, sep, min, max)
    return Grammar_obj.new(Compose.interleave(g, sep, min, max))
end

function Grammar.repeat_g(g, min, max, sep)
    return Grammar_obj.new(Compose.repeat_g(g, min, max, sep))
end

function Grammar.optional(g)
    return Grammar_obj.new(Compose.optional(g))
end

function Grammar.annotate(g, name)
    return Grammar_obj.new(Compose.annotate(g, name))
end

-- ── Fuzzer ────────────────────────────────────────────────────────────────────

function Grammar.fuzz(g, opts)         return Fuzzer.fuzz(g, opts)     end
function Grammar.fuzz_one(g, opts)     return Fuzzer.one(g, opts)      end
function Grammar.fuzz_validate(g, opts) return Fuzzer.validate(g, opts) end

-- ── Debug ─────────────────────────────────────────────────────────────────────

function Grammar.debug(g, opts)        return Debug_m.inspect(g, opts) end
function Grammar.analyze(g)            return Debug_m.analyze(g)       end
function Grammar.tree(g)               return Debug_m.tree(g)          end
function Grammar.diff(g1, g2)          return Debug_m.diff(g1, g2)     end

-- ── Except ────────────────────────────────────────────────────────────────────

function Grammar.except_chars(base_spec, exclude)
    return Except_m.except_chars(base_spec, exclude)
end

function Grammar.except_values(universe, exclude, name)
    return Grammar_obj.new(Except_m.except_values(universe, exclude, name))
end

function Grammar.except_pattern(pattern)
    return Except_m.except_pattern(pattern)
end

-- ── Runtime (lazy) ────────────────────────────────────────────────────────────

--- Create a stateful GrammarContext.
--- @param  opts  table?
--- @return GrammarContext
function Grammar.context(opts)
    return GrammarCtx().new(opts)
end

--- Create a Backtrack session (IterGen/CRANE style, KV cache rollback).
--- @param  ctx      any
--- @param  vocab    any
--- @param  sampler  any
--- @param  opts     table?
--- @return Backtrack
function Grammar.backtrack(ctx, vocab, sampler, opts)
    return Backtrack().new(ctx, vocab, sampler, opts)
end

--- Draft-Conditioned Constrained Decoding (arXiv:2603.03305).
--- @param  ctx    any
--- @param  vocab  any
--- @param  opts   table
--- @return DCCD
function Grammar.dccd(ctx, vocab, opts)
    return DCCD_m().new(ctx, vocab, opts)
end

return Grammar
