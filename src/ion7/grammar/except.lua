--- @module ion7.grammar.except
--- SPDX-License-Identifier: MIT
--- Grammar complement and exclusion operators.
---
--- GBNF cannot express true set complement (there's no "match everything
--- except X" operator). This module provides practical approximations
--- that cover the common use cases developers actually need.
---
--- Approaches (from exact to approximate):
---
--- 1. except_chars  - exact, for character-level exclusions
---    Remove specific characters from a char class.
---    [a-z] except ['a','e','i','o','u'] → [b-df-hj-np-tv-z]
---
--- 2. except_values - exact, for enum whitelist negation
---    Match anything not in a specific set of literal values.
---    Implemented as: (any string) minus known bad values → whitelist complement
---    Only works when the universe of valid values is known and finite.
---
--- 3. except_prefix - approximate, for prefix exclusion
---    Reject strings starting with specific prefixes.
---    E.g., "no key starting with _" → [^_][a-z_]*
---
--- 4. except_pattern - approximate, string-level post-filter
---    Grammar generates freely, Backtrack rejects matching strings.
---    Most general but requires backtracking support.
---
--- @usage
---   local Except = require "ion7.grammar.except"
---
---   -- Only non-vowel lowercase letters
---   local consonants = Except.except_chars("a-z", {"a","e","i","o","u"})
---
---   -- Match any status except "error"
---   local ok_status = Except.except_values(
---       { "ok", "pending", "error", "closed" },
---       { "error" }
---   )
---
---   -- Keys not starting with underscore
---   local public_key = Except.except_prefix(
---       Grammar.from_regex("[a-z][a-z0-9_]*"),
---       { "_" }
---   )
---
--- @author Ion7-Labs

local ast     = require "ion7.grammar.ast"
local Builder = require "ion7.grammar.ast.builder"

local Except = {}

--- Exclude specific characters from a character class.
---
--- Returns an AST node (char class) with the specified characters removed.
--- Exact - no approximation needed for character-level exclusions.
---
--- @param  base_spec  string   Base character class spec (e.g. "a-zA-Z0-9").
--- @param  exclude    table    Characters to exclude (e.g. {"a","e","i"}).
--- @param  negated    boolean?    Whether base_spec is already negated.
--- @return node  AST char node.
---
--- @usage
---   -- All lowercase letters except vowels
---   Except.except_chars("a-z", {"a","e","i","o","u"})
---   -- Digits except zero
---   Except.except_chars("0-9", {"0"})
function Except.except_chars(base_spec, exclude, negated)
    -- Build exclude set (raw bytes, for lookup)
    local excl = {}
    for _, c in ipairs(exclude or {}) do excl[c] = true end

    -- Encode a raw byte as a GBNF char-class fragment.
    -- Control characters and GBNF-special chars must be escaped here;
    -- doing it post-hoc on table.concat() misses raw \n/\t bytes.
    local function encode(ch)
        if     ch == '\n' then return '\\n'
        elseif ch == '\t' then return '\\t'
        elseif ch == '\r' then return '\\r'
        elseif ch == '\\' then return '\\\\'
        elseif ch == ']'  then return '\\]'
        elseif ch == '-'  then return '\\-'
        else                   return ch
        end
    end

    -- Expand base spec (GBNF char-class syntax) to encoded fragments
    local all_chars = {}
    local i = 1
    local s = base_spec
    while i <= #s do
        local c = s:sub(i, i)
        if c == '\\' and i < #s then
            -- Unescape to raw byte for exclusion check, then re-encode
            local esc = s:sub(i+1, i+1)
            local ch = esc == 'n' and '\n' or esc == 't' and '\t'
                    or esc == 'r' and '\r' or esc
            if not excl[ch] then all_chars[#all_chars+1] = encode(ch) end
            i = i + 2
        elseif i + 2 <= #s and s:sub(i+1,i+1) == '-' then
            local from = string.byte(c)
            local to   = string.byte(s, i+2)
            for code = from, to do
                local ch = string.char(code)
                if not excl[ch] then all_chars[#all_chars+1] = encode(ch) end
            end
            i = i + 3
        else
            if not excl[c] then all_chars[#all_chars+1] = encode(c) end
            i = i + 1
        end
    end

    if #all_chars == 0 then
        -- Nothing left: return empty literal
        return ast.literal("")
    end

    return ast.char(table.concat(all_chars), negated or false)
end

--- Match any value from a universe EXCEPT the excluded values.
---
--- Exact when the universe of valid values is finite and known.
--- Returns the whitelist complement as an alternation grammar.
---
--- @param  universe  table  All possible values (the full set).
--- @param  exclude   table  Values to exclude.
--- @param  name      string? Rule name (default: "except").
--- @return Builder
---
--- @usage
---   -- Any HTTP method except DELETE
---   Except.except_values(
---       { "GET", "POST", "PUT", "DELETE", "PATCH" },
---       { "DELETE" }
---   )
function Except.except_values(universe, exclude, name)
    name = name or "except"
    local excl = {}
    for _, v in ipairs(exclude or {}) do excl[v] = true end

    local allowed = {}
    for _, v in ipairs(universe) do
        if not excl[v] then allowed[#allowed+1] = v end
    end

    if #allowed == 0 then
        error("[ion7.grammar.except] except_values: no values remain after exclusion")
    end

    local Dynamic = require "ion7.grammar.from.dynamic"
    return Dynamic.from_enum(name, allowed)
end

--- Match strings that do NOT start with any of the given prefixes.
---
--- Approximate: implemented by requiring the first character to not be
--- in the prefix set. Works well for single-char prefixes (like "_", "$").
--- For multi-char prefixes, falls back to char-class exclusion of first char.
---
--- @param  base_grammar  Builder  Grammar to add prefix constraint to.
--- @param  prefixes      table    Forbidden prefix strings.
--- @param  name          string?  Rule name (default: "no_prefix").
--- @return Builder
---
--- @usage
---   -- Identifiers not starting with underscore
---   Except.except_prefix(
---       Grammar.builder():rule("root", Grammar.seq(
---           Grammar.char("a-zA-Z_"), Grammar.star(Grammar.char("a-zA-Z0-9_"))
---       )),
---       { "_" }
---   )
function Except.except_prefix(base_grammar, prefixes, name)
    name = name or "no_prefix"

    -- Extract single-char prefixes (we can handle these exactly)
    local forbidden_first = {}
    for _, p in ipairs(prefixes or {}) do
        if #p >= 1 then forbidden_first[p:sub(1,1)] = true end
    end

    if next(forbidden_first) == nil then
        -- No prefixes to exclude - return base unchanged
        return base_grammar._builder or base_grammar
    end

    -- Build a "first char not in forbidden" node
    local forbidden_chars = {}
    for c in pairs(forbidden_first) do forbidden_chars[#forbidden_chars+1] = c end
    local excl_spec = table.concat(forbidden_chars)
    -- Escape for char class
    excl_spec = excl_spec:gsub("\\", "\\\\"):gsub("%]", "\\]")

    local b = Builder.new({ root = name })
    -- Add base grammar rules (prefixed)
    local base_b = base_grammar._builder or base_grammar
    local base_root = base_b._root or "root"
    for _, r in ipairs(base_b._rules or {}) do
        if r.name ~= base_root then
            b:rule("base_" .. r.name, r.body)
        end
    end

    -- The constraint: first char must not be forbidden
    -- We approximate by requiring first char from [^forbidden]
    local not_prefix = ast.char(excl_spec, true)  -- negated

    -- Find base root body and wrap with prefix check
    local base_body
    for _, r in ipairs(base_b._rules or {}) do
        if r.name == base_root then base_body = r.body; break end
    end

    if base_body then
        -- The base grammar already ensures valid chars; we add a constraint
        -- that the first char is not in forbidden_first.
        -- Simplification: replace the first char node with not_prefix + rest.
        b:rule(name, ast.seq(not_prefix, ast.ref("base_rest")))
        -- base_rest is everything the base grammar can generate after first char
        -- Approximation: use the full base body (slight over-approximation)
        b:rule("base_rest", base_body)
    else
        b:rule(name, ast.seq(not_prefix, ast.star(ast.char("a-zA-Z0-9_-"))))
    end

    return b
end

--- Backtrack-based exclusion - use with Grammar.backtrack().
---
--- The most general approach: generate freely but reject strings matching
--- the exclusion pattern. Requires ion7-core Backtrack object.
---
--- This is a factory that returns a validator function suitable for
--- Backtrack:constrain() or Backtrack:backward().
---
--- @param  pattern  string  Lua pattern string. Strings matching this are rejected.
--- @return function  fn(text) → bool  true = accept, false = reject.
---
--- @usage
---   local bt = Grammar.backtrack(ctx, vocab, sampler)
---   bt:checkpoint("field_name")
---   bt:forward(function(p) return p:find("%s") end)
---   bt:constrain("field_name", Except.except_pattern("^_"))
function Except.except_pattern(pattern)
    return function(text)
        return not text:find(pattern)
    end
end

return Except
