--- @module ion7.grammar.ast.compiler
--- SPDX-License-Identifier: MIT
--- AST → GBNF string compiler.
---
--- Takes a set of named rules and produces a valid GBNF string for
--- llama.cpp's grammar-constrained sampler. Used internally by `Builder:compile()`.
---
--- GBNF syntax reference:
---   root  ::= expression
---   rule  ::= "text" | [a-z] | other-rule | ( a b ) | a* | a+ | a? | a{n,m}
---
--- Rule name constraint: `[a-z][a-z0-9-]*` — letters, digits, hyphens only.
--- Underscores are NOT valid in this llama.cpp build.
---
--- @usage
---   local compiler = require "ion7.grammar.ast.compiler"
---   local gbnf = compiler.compile(rules, "root", true)
---
--- @author Ion7-Labs

local table_concat = table.concat
local table_insert = table.insert
local table_unpack = table.unpack or unpack
local string_format = string.format
local tostring     = tostring
local ipairs       = ipairs

local compiler = {}

-- ── Escape helpers ─────────────────────────────────────────────────────────────

--- Escape a raw string so it is safe to embed inside GBNF double-quoted
--- literal syntax: backslashes and double-quotes are escaped; newline and
--- tab are converted to their two-character escape sequences.
--- @param  s  string  Raw string value.
--- @return string  Escaped string (no surrounding quotes).
--- @private
local function escape_literal(s)
    local r = s:gsub('\\', '\\\\')
    r = r:gsub('"',  '\\"')
    r = r:gsub('\n', '\\n')
    r = r:gsub('\t', '\\t')
    return r
end

-- ── Node → GBNF string ─────────────────────────────────────────────────────────

--- Forward declaration - compile_seq and compile_alt call back into this.
--- @private
local compile_node

--- Compile a literal node to a double-quoted GBNF string.
--- @private
local function compile_literal(node)
    return '"' .. escape_literal(node.value) .. '"'
end

--- Compile a char-class node to a GBNF bracket expression.
--- @private
local function compile_char(node)
    if node.negated then return '[^' .. node.spec .. ']'
    else return '[' .. node.spec .. ']' end
end

--- Compile a ref node to its rule name.
--- @private
local function compile_ref(node)
    return node.name
end

--- Compile a seq node: items joined by spaces.
--- @private
local function compile_seq(node, prec)
    local parts = {}
    for _, item in ipairs(node.items) do
        parts[#parts + 1] = compile_node(item, "seq")
    end
    local result = table_concat(parts, " ")
    if prec == "alt" or prec == "rep" then
        return "( " .. result .. " )"
    end
    return result
end

--- Compile an alt node: alternatives joined by " | ".
--- @private
local function compile_alt(node, prec)
    local parts = {}
    for _, item in ipairs(node.items) do
        parts[#parts + 1] = compile_node(item, "alt")
    end
    local result = table_concat(parts, " | ")
    if prec == "seq" or prec == "rep" then
        return "( " .. result .. " )"
    end
    return result
end

--- Compile a rep node using GBNF suffix operators or {n,m} notation.
--- @private
local function compile_rep(node)
    local inner = compile_node(node.node, "rep")
    local min, max = node.min, node.max

    if min == 0 and max == -1 then return inner .. "*" end
    if min == 1 and max == -1 then return inner .. "+" end
    if min == 0 and max ==  1 then return inner .. "?" end

    local max_str = max == -1 and "" or tostring(max)
    if min == max then
        return inner .. "{" .. min .. "}"
    else
        return inner .. "{" .. min .. "," .. max_str .. "}"
    end
end

--- Compile a group node.
--- @private
local function compile_group(node)
    return "( " .. compile_node(node.node) .. " )"
end

--- Dispatch compilation to the correct handler based on node.kind.
--- @private
compile_node = function(node, prec)
    if not node then error("[ion7.grammar.ast.compiler] nil node") end
    local k = node.kind
    if     k == "literal" then return compile_literal(node)
    elseif k == "char"    then return compile_char(node)
    elseif k == "ref"     then return compile_ref(node)
    elseif k == "seq"     then return compile_seq(node, prec)
    elseif k == "alt"     then return compile_alt(node, prec)
    elseif k == "rep"     then return compile_rep(node)
    elseif k == "group"   then return compile_group(node)
    else error("[ion7.grammar.ast.compiler] unknown node kind: " .. tostring(k))
    end
end

-- ── Grammar → GBNF string ──────────────────────────────────────────────────────

--- Compile a set of named rules to a GBNF string.
---
--- The root rule is always placed first in the output regardless of
--- definition order. When `whitespace` is true and a `ws` rule is missing
--- but referenced, a default `ws ::= [ \t\n]*` rule is appended.
---
--- @param  rules       table    Array of { name, body } pairs.
--- @param  root        string?  Root rule name (default: "root").
--- @param  whitespace  boolean? Inject ws rule if referenced but absent (default: true).
--- @return string  GBNF string (no trailing newline).
--- @error  When the root rule is not found in the rules array.
function compiler.compile(rules, root, whitespace)
    root = root or "root"
    if whitespace == nil then whitespace = true end

    local by_name = {}
    for _, r in ipairs(rules) do by_name[r.name] = true end

    -- Inject ws ONLY when actually referenced by another rule.
    if whitespace and not by_name["ws"] then
        local ws_referenced = false
        local function scan(node)
            if not node then return end
            if node.kind == "ref" and node.name == "ws" then
                ws_referenced = true; return
            end
            if node.items then
                for _, item in ipairs(node.items) do scan(item) end
            end
            if node.node then scan(node.node) end
        end
        for _, r in ipairs(rules) do
            scan(r.body)
            if ws_referenced then break end
        end
        if ws_referenced then
            rules = { table_unpack(rules) }
            table_insert(rules, {
                name = "ws",
                body = { kind = "rep",
                         node = { kind = "char", spec = " \\t\\n" },
                         min = 0, max = -1 }
            })
        end
    end

    local lines    = {}
    local has_root = false

    for _, r in ipairs(rules) do
        local line = r.name .. " ::= " .. compile_node(r.body)
        if r.name == root then
            table_insert(lines, 1, line)
            has_root = true
        else
            lines[#lines + 1] = line
        end
    end

    if not has_root then
        error("[ion7.grammar.ast.compiler] root rule '" .. root .. "' not found")
    end

    return table_concat(lines, "\n")
end

return compiler
