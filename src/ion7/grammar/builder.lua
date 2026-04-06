--- @module ion7.grammar.builder
--- SPDX-License-Identifier: MIT
--- Fluent API for building GBNF grammars programmatically.
---
--- GrammarBuilder maintains a set of named rules. Call builder methods
--- to define rules, then :compile() to get the GBNF string.
---
--- @usage
---   local Grammar = require "ion7.grammar"
---
---   local g = Grammar.builder()
---       :rule("root",
---           Grammar.seq(
---               Grammar.literal("{"),
---               Grammar.ref("ws"),
---               Grammar.ref("members"),
---               Grammar.ref("ws"),
---               Grammar.literal("}")
---           )
---       )
---       :rule("members",
---           Grammar.seq(
---               Grammar.ref("pair"),
---               Grammar.star(Grammar.seq(
---                   Grammar.literal(","),
---                   Grammar.ref("ws"),
---                   Grammar.ref("pair")
---               ))
---           )
---       )
---       :compile()
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast      = require "ion7.grammar.ast"
local compiler = require "ion7.grammar.compiler"

--- @class Builder
--- Fluent grammar builder: accumulates named rules and compiles to GBNF.
--- @field _rules  table   Ordered array of { name, body } pairs.
--- @field _names  table   Set of defined rule names for fast dedup lookup.
--- @field _root   string  Current root rule name.
local Builder = {}
Builder.__index = Builder

--- Create a new GrammarBuilder.
---
--- @param  opts  table?
---   opts.root  string?  Root rule name (default: "root").
--- @return Builder
function Builder.new(opts)
    opts = opts or {}
    return setmetatable({
        _rules = {},          -- ordered array of { name, body }
        _names = {},          -- set of defined names (dedup check)
        _root  = opts.root or "root",
    }, Builder)
end

--- Define a named rule.
---
--- Calling :rule() with the same name twice replaces the previous definition.
---
--- @param  name  string  Rule name. Must match [a-zA-Z_][a-zA-Z0-9_-]*.
--- @param  body  node    AST node (from Grammar.seq, Grammar.alt, etc.)
--- @return Builder  self (fluent)
function Builder:rule(name, body)
    if self._names[name] then
        -- Replace existing rule in-place to preserve definition order.
        for i, r in ipairs(self._rules) do
            if r.name == name then
                self._rules[i] = { name = name, body = body }
                return self
            end
        end
    end
    self._rules[#self._rules + 1] = { name = name, body = body }
    self._names[name] = true
    return self
end

--- Set the root rule name used by :compile().
---
--- @param  name  string  Name of the rule to treat as root.
--- @return Builder  self
function Builder:root(name)
    self._root = name
    return self
end

--- Merge rules from another Builder or rule list.
---
--- Rules whose names already exist in self are skipped (no overwrite).
--- Useful for composing grammars, e.g. embedding a JSON grammar into a
--- larger one.
---
--- @param  other  Builder|table  Another builder or { name, body } array.
--- @return Builder  self
function Builder:merge(other)
    local rules = type(other) == "table" and other._rules or other
    for _, r in ipairs(rules) do
        if not self._names[r.name] then
            self:rule(r.name, r.body)
        end
    end
    return self
end

--- Compile all rules to a GBNF string.
---
--- @param  opts  table?
---   opts.whitespace  bool?  Auto-inject ws rule when referenced (default: true).
--- @return string  GBNF string.
function Builder:compile(opts)
    opts = opts or {}
    return compiler.compile(
        self._rules,
        self._root,
        opts.whitespace ~= false
    )
end

--- Return a shallow copy of this builder's rule list.
---
--- Each entry is a table with keys `name` (string) and `body` (node).
---
--- @return table  Array of { name, body } pairs.
function Builder:rules()
    local out = {}
    for i, r in ipairs(self._rules) do out[i] = r end
    return out
end

--- List defined rule names in definition order.
---
--- @return table  Array of rule name strings.
function Builder:names()
    local out = {}
    for _, r in ipairs(self._rules) do out[#out + 1] = r.name end
    return out
end

return Builder
