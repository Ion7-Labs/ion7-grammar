--- SPDX-License-Identifier: MIT
--- Grammar_obj — the composable grammar handle returned by all constructors.
---
--- Every public constructor in ion7.grammar returns a Grammar_obj.
--- Grammar_obj wraps a Builder and exposes the high-level user-facing API:
--- to_gbnf(), merge(), union(), fuzz(), inspect(), trigger_words(), etc.
---
--- Methods that compose grammars (union, then_) are thin delegates to the
--- Compose module loaded lazily to avoid circular deps at module load time.
---
--- @author Ion7-Labs
--- @version 0.1.0

-- ── First-set computation (used by trigger_words) ────────────────────────────
-- Walks a grammar AST and collects all string prefixes that can start a match.
-- Used to auto-derive trigger_words for ion7_csampler grammar_lazy (CRANE).

local function _first_literals(node, rules_map, visited, acc, max_len)
    if not node then return end
    local k = node.kind
    if k == "literal" then
        local s = node.value:sub(1, max_len)
        if #s > 0 then acc[s] = true end
    elseif k == "seq" then
        if node.items and node.items[1] then
            _first_literals(node.items[1], rules_map, visited, acc, max_len)
        end
    elseif k == "alt" then
        for _, child in ipairs(node.items or {}) do
            _first_literals(child, rules_map, visited, acc, max_len)
        end
    elseif k == "rep" then
        if (node.min or 0) >= 1 then
            _first_literals(node.node, rules_map, visited, acc, max_len)
        end
    elseif k == "ref" then
        local name = node.name
        if not visited[name] and rules_map[name] then
            visited[name] = true
            _first_literals(rules_map[name], rules_map, visited, acc, max_len)
        end
    elseif k == "group" then
        _first_literals(node.node, rules_map, visited, acc, max_len)
    end
    -- char nodes: too broad (e.g. [0-9] → 10 triggers), skip intentionally
end

-- ── Grammar_obj ───────────────────────────────────────────────────────────────

--- @class Grammar_obj
local Grammar_obj = {}
Grammar_obj.__index = Grammar_obj

--- Construct a Grammar_obj wrapping a Builder.
--- @param  b  any  Builder instance (required).
--- @return Grammar_obj
function Grammar_obj.new(b)
    assert(b, "[ion7.grammar.grammar_obj] builder required")
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
--- @return any  Builder
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
    local Compose = require "ion7.grammar.compose"
    return Grammar_obj.new(Compose.union(self, other))
end

--- Compose: match this grammar followed by another (sequence).
--- @param  other  Grammar_obj
--- @param  sep    any?  Optional separator AST node.
--- @return Grammar_obj
function Grammar_obj:then_(other, sep)
    local Compose = require "ion7.grammar.compose"
    return Grammar_obj.new(Compose.sequence(self, other, sep and { separator = sep } or nil))
end

--- Derive the set of string prefixes that can start a valid match of this
--- grammar, suitable as trigger_words for ion7_csampler grammar_lazy (CRANE).
---
--- @param  opts  table?
---   opts.max_prefix  number?  Truncate each trigger to this many chars (default: 8).
--- @return table  Sorted array of trigger strings.
function Grammar_obj:trigger_words(opts)
    opts = opts or {}
    local b = self._builder
    if not b then return {} end
    local max_len    = opts.max_prefix or 8
    local rules_map  = {}
    for _, r in ipairs(b:rules()) do rules_map[r.name] = r.body end
    local root_name  = b._root
    local root_body  = rules_map[root_name]
    if not root_body then return {} end
    local acc = {}
    _first_literals(root_body, rules_map, { [root_name] = true }, acc, max_len)
    local out = {}
    for s in pairs(acc) do out[#out + 1] = s end
    table.sort(out)
    return out
end

--- Fuzz: generate random valid strings from this grammar.
--- @param  opts  table?  { count, seed, max_rep, max_depth }
--- @return table   samples  Array of generated strings.
--- @return number  seed     RNG seed used (for reproduction).
function Grammar_obj:fuzz(opts)
    local Fuzzer = require "ion7.grammar.dev.fuzz"
    return Fuzzer.fuzz(self, opts)
end

--- Debug: return annotated GBNF with rule stats.
--- @return string
function Grammar_obj:inspect()
    local Debug = require "ion7.grammar.dev.debug"
    return Debug.inspect(self)
end

-- ── RawGrammar ────────────────────────────────────────────────────────────────
-- A Grammar_obj backed by a raw GBNF string rather than a Builder.
-- Created by Grammar.raw(). Does not support merge, fuzz, or trigger_words.

local RawGrammar = setmetatable({}, { __index = Grammar_obj })
RawGrammar.__index = RawGrammar

--- @param  gbnf  string  Raw GBNF string.
--- @return Grammar_obj
function RawGrammar.new(gbnf)
    return setmetatable({ _builder = nil, _gbnf = gbnf }, RawGrammar)
end

function RawGrammar:to_gbnf()       return self._gbnf end
function RawGrammar:builder()       error("[ion7.grammar] raw grammar has no builder") end
function RawGrammar:merge()         error("[ion7.grammar] raw grammar cannot be merged") end
function RawGrammar:rules()         return {} end
function RawGrammar:fuzz()          error("[ion7.grammar] raw grammar cannot be fuzzed") end
function RawGrammar:inspect()       return self._gbnf end
function RawGrammar:trigger_words() return {} end

return {
    Grammar_obj = Grammar_obj,
    RawGrammar  = RawGrammar,
}
