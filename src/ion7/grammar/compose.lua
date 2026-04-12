--- @module ion7.grammar.compose
--- SPDX-License-Identifier: MIT
--- Grammar composition operators.
---
--- All operators return Grammar_obj (or Builder for internal use).
--- Grammars compose correctly even when they have internal sub-rules:
--- refs are rewritten when rules are prefixed, preventing broken references
--- or self-referential loops.
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast     = require "ion7.grammar.ast"
local Builder = require "ion7.grammar.ast.builder"

local Compose = {}

-- ── AST ref rewriting ─────────────────────────────────────────────────────────

--- Deep-copy an AST node, rewriting ref names according to a mapping.
---
--- Recursively traverses the AST and replaces every `ref` node whose name
--- appears in `name_map` with a new ref using the mapped name. All other
--- node kinds are deep-copied unchanged. seq/alt items arrays are copied
--- element by element so the original AST is never mutated.
---
--- Used when merging rules from one grammar into another with a prefix,
--- so that internal references point to the new prefixed names.
---
--- @param  node      table  AST node to transform (any kind).
--- @param  name_map  table  { old_name = new_name } substitution map.
--- @return table  New AST node with all matching refs rewritten.
local function rewrite_refs(node, name_map)
    if not node then return node end
    local k = node.kind

    if k == "ref" then
        return ast.ref(name_map[node.name] or node.name)

    elseif k == "seq" or k == "alt" then
        local new_items = {}
        for i, item in ipairs(node.items) do
            new_items[i] = rewrite_refs(item, name_map)
        end
        return { kind = k, items = new_items }

    elseif k == "rep" then
        return { kind = k, node = rewrite_refs(node.node, name_map),
                 min = node.min, max = node.max }

    elseif k == "group" then
        return { kind = k, node = rewrite_refs(node.node, name_map) }

    else
        return node  -- literal, char: no refs to rewrite
    end
end

-- ── Internal: prefix ALL rules from a grammar ─────────────────────────────────

--- Add all rules from source_b into target_b with a prefix.
--- All internal refs are rewritten to use the new prefixed names.
--- The root rule of source_b becomes prefix-root_name in target_b.
---
--- @param  target_b   Builder  Destination builder.
--- @param  source_b   Builder  Source builder.
--- @param  prefix     string   Prefix to prepend (e.g. "a", "b").
--- @return string  The new name of source_b's root rule in target_b.
local function prefix_grammar(target_b, source_b, prefix)
    local rules    = source_b._rules or {}
    local root_src = source_b._root or "root"

    -- Build the name map: old → new
    local name_map = {}
    for _, r in ipairs(rules) do
        name_map[r.name] = prefix .. "-" .. r.name
    end

    -- Add all rules with rewritten refs
    for _, r in ipairs(rules) do
        local new_name = name_map[r.name]
        if not target_b._names[new_name] then
            local new_body = rewrite_refs(r.body, name_map)
            target_b:rule(new_name, new_body)
        end
    end

    return name_map[root_src]  -- new name of the root rule
end

-- ── Internal: extract root info from a Grammar_obj or Builder ─────────────────

local function get_builder(g)
    return g._builder or (type(g.builder) == "function" and g:builder()) or g
end

-- ── Composition operators ─────────────────────────────────────────────────────

--- Union: match either grammar a or grammar b.
---
--- All rules from both grammars are added with "a-" and "b-" prefixes.
--- Internal refs are rewritten so no broken references occur.
---
--- @param  a     Grammar_obj|Builder
--- @param  b     Grammar_obj|Builder
--- @param  opts  table?  { root = "root" }
--- @return Builder
function Compose.union(a, b, opts)
    opts = opts or {}
    local ba = get_builder(a)
    local bb = get_builder(b)
    local result = Builder.new({ root = opts.root or "root" })

    local root_a = prefix_grammar(result, ba, "a")
    local root_b = prefix_grammar(result, bb, "b")

    result:rule(opts.root or "root", ast.alt(ast.ref(root_a), ast.ref(root_b)))
    return result
end

--- Sequence: match grammar a followed immediately by grammar b.
---
--- @param  a     Grammar_obj|Builder
--- @param  b     Grammar_obj|Builder
--- @param  opts  table?  { root = "root", separator = node? }
--- @return Builder
function Compose.sequence(a, b, opts)
    opts = opts or {}
    local ba = get_builder(a)
    local bb = get_builder(b)
    local result = Builder.new({ root = opts.root or "root" })

    local root_a = prefix_grammar(result, ba, "a")
    local root_b = prefix_grammar(result, bb, "b")

    local parts = { ast.ref(root_a) }
    if opts.separator then parts[#parts + 1] = opts.separator end
    parts[#parts + 1] = ast.ref(root_b)

    result:rule(opts.root or "root", ast.seq(table.unpack(parts)))
    return result
end

--- Repeat: match grammar g between min and max times.
---
--- @param  g    Grammar_obj|Builder
--- @param  min  number?  Minimum repetitions (default: 0).
--- @param  max  number?  Maximum repetitions (default: -1 = unlimited).
--- @param  sep  table|string|nil  Optional AST separator node (or literal string) between repetitions.
--- @return Builder
function Compose.repeat_g(g, min, max, sep)
    min = min or 0
    max = max or -1
    local bg = get_builder(g)
    local result = Builder.new()

    local root_g = prefix_grammar(result, bg, "inner")
    local item = ast.ref(root_g)

    local rep_body
    if sep then
        local sep_item = ast.seq(sep, item)
        if min == 0 then
            rep_body = ast.opt(ast.seq(item,
                ast.rep(sep_item, 0, max == -1 and -1 or math.max(0, max - 1))))
        else
            rep_body = ast.seq(item,
                ast.rep(sep_item, min - 1, max == -1 and -1 or math.max(0, max - 1)))
        end
    else
        rep_body = ast.rep(item, min, max)
    end
    result:rule("root", rep_body)
    return result
end

--- Optional: match grammar g or the empty string.
---
--- @param  g  Grammar_obj|Builder
--- @return Builder
function Compose.optional(g)
    return Compose.repeat_g(g, 0, 1)
end

--- Wrap: surround grammar with prefix and suffix literals.
---
--- @param  g    Grammar_obj|Builder
--- @param  pre  string  Prefix literal (e.g. "[").
--- @param  suf  string  Suffix literal (e.g. "]").
--- @param  ws   boolean?   Insert whitespace between delimiters (default: true).
--- @return Builder
function Compose.wrap(g, pre, suf, ws)
    if ws == nil then ws = true end
    local bg = get_builder(g)
    local result = Builder.new()

    local root_g = prefix_grammar(result, bg, "inner")
    if ws then
        result:rule("ws", ast.star(ast.char(" \t\n")))
        result:rule("root", ast.seq(
            ast.literal(pre), ast.ref("ws"),
            ast.ref(root_g),
            ast.ref("ws"), ast.literal(suf)
        ))
    else
        result:rule("root", ast.seq(
            ast.literal(pre), ast.ref(root_g), ast.literal(suf)
        ))
    end
    return result
end

--- Interleave: match grammar g with sep between each occurrence.
--- Equivalent to: g (sep g)* - one or more gs separated by sep.
---
--- @param  g    Grammar_obj|Builder
--- @param  sep  string|table  Separator: a literal string (e.g. ",") or a pre-built AST node.
--- @param  min  number?       Minimum elements (default: 1).
--- @param  max  number?       Maximum elements (default: -1 = unlimited).
--- @return Builder
function Compose.interleave(g, sep, min, max)
    min = min or 1
    max = max or -1
    local sep_node = type(sep) == "string" and ast.literal(sep) or sep
    return Compose.repeat_g(g, min, max, sep_node)
end

--- Annotate: wrap a grammar with a named alias rule.
---
--- @param  g     Grammar_obj|Builder
--- @param  name  string  New root rule name.
--- @return Builder
function Compose.annotate(g, name)
    local bg = get_builder(g)
    local result = Builder.new({ root = name })

    local root_g = prefix_grammar(result, bg, "inner")
    result:rule(name, ast.ref(root_g))
    return result
end

return Compose
