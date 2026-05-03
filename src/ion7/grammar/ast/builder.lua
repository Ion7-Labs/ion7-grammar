--- @module ion7.grammar.ast.builder
--- SPDX-License-Identifier: MIT
--- Fluent API for building GBNF grammars programmatically.
---
--- `Builder` maintains an ordered set of named rules. Add rules with
--- `:rule()`, then call `:compile()` to get the GBNF string ready for
--- llama.cpp. Typically obtained via `Grammar.builder()` rather than
--- required directly.
---
--- @usage
---   local Grammar = require "ion7.grammar"
---
---   local b = Grammar.builder()
---   b:rule("digit", Grammar.char("0-9"))
---   b:rule("root",  Grammar.plus(Grammar.ref("digit")))
---   print(b:compile())
---   -- root ::= [0-9]+
---   -- digit ::= [0-9]
---
--- @author Ion7-Labs

local compiler = require "ion7.grammar.ast.compiler"

--- @class Builder
local Builder = {}
Builder.__index = Builder

--- Create a new GrammarBuilder.
--- @param  opts  table?
---   opts.root  string?  Root rule name (default: "root").
--- @return Builder
function Builder.new(opts)
    opts = opts or {}
    return setmetatable({
        _rules = {},
        _names = {},
        _root  = opts.root or "root",
    }, Builder)
end

--- Define a named rule.
---
--- Calling :rule() with the same name twice replaces the previous definition.
---
--- @param  name  string  Rule name.
--- @param  body  table   AST node.
--- @return Builder  self (fluent)
function Builder:rule(name, body)
    local idx = self._names[name]
    if idx then
        self._rules[idx] = { name = name, body = body }
        return self
    end
    local n = #self._rules + 1
    self._rules[n] = { name = name, body = body }
    self._names[name] = n
    return self
end

--- Set the root rule name used by :compile().
--- @param  name  string
--- @return Builder  self
function Builder:root(name)
    self._root = name
    return self
end

--- Merge rules from another Builder or rule list.
--- Rules whose names already exist in self are skipped (no overwrite).
--- @param  other  Builder|table
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
--- @param  opts  table?
---   opts.whitespace  boolean?  Auto-inject ws rule when referenced (default: true).
--- @return string
function Builder:compile(opts)
    opts = opts or {}
    return compiler.compile(
        self._rules,
        self._root,
        opts.whitespace ~= false
    )
end

--- Return a shallow copy of this builder's rule list.
--- @return table  Array of { name, body } pairs.
function Builder:rules()
    local out = {}
    for i, r in ipairs(self._rules) do out[i] = r end
    return out
end

--- List defined rule names in definition order.
--- @return table  Array of rule name strings.
function Builder:names()
    local out = {}
    for _, r in ipairs(self._rules) do out[#out + 1] = r.name end
    return out
end

return Builder
