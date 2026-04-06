--- @module ion7.grammar.compiler
--- SPDX-License-Identifier: MIT
--- AST → GBNF string compiler.
---
--- Takes a set of named rules and produces a valid GBNF string for
--- llama.cpp's grammar-constrained sampler.
---
--- GBNF format:
---   root  ::= expression
---   rule  ::= "text" | [a-z] | other-rule | ( a b ) | a* | a{n,m}
---
--- Rule names: [a-z][a-z0-9-]* - letters, digits, hyphens ONLY.
--- Underscores are NOT valid in this llama.cpp build.
---
--- @author Ion7-Labs
--- @version 0.1.0

--- AST node table. All fields depend on `kind`; see ast.lua for the full
--- per-kind field inventory.
--- @alias node table

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
--- @param  node  node  { kind="literal", value=string }
--- @return string
--- @private
local function compile_literal(node)
    return '"' .. escape_literal(node.value) .. '"'
end

--- Compile a char-class node to a GBNF bracket expression.
--- @param  node  node  { kind="char", spec=string, negated=bool }
--- @return string  e.g. "[a-z]" or "[^0-9]"
--- @private
local function compile_char(node)
    if node.negated then return '[^' .. node.spec .. ']'
    else return '[' .. node.spec .. ']' end
end

--- Compile a ref node to its rule name.
--- @param  node  node  { kind="ref", name=string }
--- @return string
--- @private
local function compile_ref(node)
    return node.name
end

--- Wrap a compiled expression in parentheses if it contains spaces and is
--- not already parenthesised. Used to ensure operators bind correctly.
--- @param  s  string  Compiled expression fragment.
--- @return string
--- @private
local function maybe_paren(s)
    if s:find(" ", 1, true) and not s:match("^%(") then
        return "( " .. s .. " )"
    end
    return s
end

--- Compile a seq node: items joined by spaces.
---
--- Sequences inside `alt` or `rep` context are automatically parenthesised
--- so the enclosing operator binds to the whole sequence.
---
--- @param  node  node    { kind="seq", items=table }
--- @param  prec  string? Enclosing operator context: "alt" | "rep" | nil.
--- @return string
--- @private
local function compile_seq(node, prec)
    local parts = {}
    for _, item in ipairs(node.items) do
        parts[#parts + 1] = compile_node(item, "seq")
    end
    local result = table.concat(parts, " ")
    -- Sequences inside alt or rep MUST be grouped so the operator binds
    -- to the whole sequence, not just the last token.
    if prec == "alt" or prec == "rep" then
        return "( " .. result .. " )"
    end
    return result
end

--- Compile an alt node: alternatives joined by " | ".
---
--- Alternatives inside `seq` or `rep` context are automatically parenthesised.
---
--- @param  node  node    { kind="alt", items=table }
--- @param  prec  string? Enclosing operator context: "seq" | "rep" | nil.
--- @return string
--- @private
local function compile_alt(node, prec)
    local parts = {}
    for _, item in ipairs(node.items) do
        parts[#parts + 1] = compile_node(item, "alt")
    end
    local result = table.concat(parts, " | ")
    -- Alternatives inside seq or rep must be grouped.
    if prec == "seq" or prec == "rep" then
        return "( " .. result .. " )"
    end
    return result
end

--- Compile a rep node using GBNF suffix operators or {n,m} notation.
---
--- Common cases use the compact suffixes *, +, ?. All other bounded
--- repetitions use the GBNF {n,m} form, which is cleaner and correct
--- for multi-token inner expressions.
---
--- @param  node  node  { kind="rep", node=node, min=number, max=number }
--- @return string
--- @private
local function compile_rep(node)
    local inner = compile_node(node.node, "rep")
    local min, max = node.min, node.max

    -- Compact suffixes for the common cases.
    if min == 0 and max == -1 then return inner .. "*" end
    if min == 1 and max == -1 then return inner .. "+" end
    if min == 0 and max ==  1 then return inner .. "?" end

    -- Use GBNF {n,m} notation for bounded repetitions.
    -- This correctly handles multi-token inner expressions (a manual
    -- expansion like a b? a b? ... was broken for seq inner nodes).
    local max_str = max == -1 and "" or tostring(max)
    if min == max then
        return inner .. "{" .. min .. "}"
    else
        return inner .. "{" .. min .. "," .. max_str .. "}"
    end
end

--- Compile a group node: wraps inner expression in explicit parentheses.
--- @param  node  node  { kind="group", node=node }
--- @return string
--- @private
local function compile_group(node)
    return "( " .. compile_node(node.node) .. " )"
end

--- Dispatch compilation to the correct handler based on node.kind.
---
--- @param  node  node    AST node to compile.
--- @param  prec  string? Enclosing context hint passed to seq/alt handlers.
--- @return string  GBNF fragment for this node.
--- @private
compile_node = function(node, prec)
    if not node then error("[ion7.grammar.compiler] nil node") end
    local k = node.kind
    if     k == "literal" then return compile_literal(node)
    elseif k == "char"    then return compile_char(node)
    elseif k == "ref"     then return compile_ref(node)
    elseif k == "seq"     then return compile_seq(node, prec)
    elseif k == "alt"     then return compile_alt(node, prec)
    elseif k == "rep"     then return compile_rep(node)
    elseif k == "group"   then return compile_group(node)
    else error("[ion7.grammar.compiler] unknown node kind: " .. tostring(k))
    end
end

-- ── Grammar → GBNF string ──────────────────────────────────────────────────────

--- Compile a set of named rules to a GBNF string.
---
--- The root rule is always placed first in the output regardless of
--- definition order. When `whitespace` is true and a `ws` rule is missing
--- but referenced, a default `ws ::= [ \t\n]*` rule is appended.
---
--- @param  rules       table   Array of { name, body } pairs.
--- @param  root        string? Root rule name (default: "root").
--- @param  whitespace  bool?   Inject ws rule if referenced but absent (default: true).
--- @return string  GBNF string (no trailing newline).
--- @error  When the root rule is not found in the rules array.
function compiler.compile(rules, root, whitespace)
    root = root or "root"
    if whitespace == nil then whitespace = true end

    local by_name = {}
    for _, r in ipairs(rules) do by_name[r.name] = true end

    -- Inject ws ONLY when actually referenced by another rule.
    -- Unreferenced rules cause issues in some llama.cpp versions.
    -- \r removed: not supported in all llama.cpp GBNF builds.
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
            rules = { table.unpack(rules) }
            table.insert(rules, {
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
            table.insert(lines, 1, line)
            has_root = true
        else
            lines[#lines + 1] = line
        end
    end

    if not has_root then
        error("[ion7.grammar.compiler] root rule '" .. root .. "' not found")
    end

    return table.concat(lines, "\n")
end

return compiler
