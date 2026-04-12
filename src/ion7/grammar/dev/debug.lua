--- @module ion7.grammar.dev.debug
--- SPDX-License-Identifier: MIT
--- Grammar debugging and introspection tools.
---
--- Provides human-readable representations of grammars, rule analysis,
--- complexity metrics, and visual diff between grammar versions.
--- Typically accessed via `Grammar.debug()`, `Grammar.analyze()`,
--- `Grammar.tree()`, and `Grammar.diff()`.
---
--- @usage
---   local Grammar = require "ion7.grammar"
---
---   local g = Grammar.from_type({ name = "string", age = "integer" })
---
---   -- Annotated GBNF with rule stats
---   print(Grammar.debug(g))
---
---   -- Structured analysis
---   local a = Grammar.analyze(g)
---   print(a.n_rules, a.root, #a.unreferenced)
---
---   -- ASCII dependency tree
---   print(Grammar.tree(g))
---
---   -- Diff two grammars
---   local g2 = Grammar.from_type({ name = "string" })
---   print(Grammar.diff(g, g2))
---
--- @author Ion7-Labs
--- @version 0.1.0

local debug_m = {}

-- ── AST reference counter ─────────────────────────────────────────────────────

local function collect_refs(node, counts)
    if not node then return end
    if node.kind == "ref" then
        counts[node.name] = (counts[node.name] or 0) + 1
    elseif node.items then
        for _, item in ipairs(node.items) do collect_refs(item, counts) end
    elseif node.node then
        collect_refs(node.node, counts)
    end
end

local function build_ref_counts(rules)
    local ref_counts = {}
    for _, r in ipairs(rules) do
        local counts = {}
        collect_refs(r.body, counts)
        for name, n in pairs(counts) do
            ref_counts[name] = (ref_counts[name] or 0) + n
        end
    end
    return ref_counts
end

--- Pretty-print a grammar as annotated GBNF with rule statistics.
---
--- @param  grammar  any  Grammar_obj or Builder.
--- @param  opts     table?
---   opts.show_stats  boolean?  Show rule stats. Default: true.
---   opts.max_width   number?   Wrap long rules. Default: 80.
--- @return string
function debug_m.inspect(grammar, opts)
    opts = opts or {}
    local show_stats = opts.show_stats ~= false
    local b = grammar._builder or grammar
    if not b or not b._rules then
        return "(empty grammar)"
    end

    local lines = {}
    lines[#lines+1] = string.format("Grammar - %d rules", #b._rules)
    lines[#lines+1] = string.rep("─", 60)

    local ref_counts = build_ref_counts(b._rules)

    local gbnf = b:compile()
    for _, r in ipairs(b._rules) do
        local rule_gbnf = r.name .. " ::= ..."
        for line in gbnf:gmatch("[^\n]+") do
            if line:sub(1, #r.name + 4) == r.name .. " ::=" then
                rule_gbnf = line
                break
            end
        end

        lines[#lines+1] = rule_gbnf
        if show_stats then
            local refs   = ref_counts[r.name] or 0
            local marker = r.name == (b._root or "root") and " [ROOT]" or ""
            local ref_str = refs > 0
                and string.format(" [referenced %d×]", refs)
                or  " [unreferenced]"
            lines[#lines+1] = string.format(
                "  ^-- %s%s", marker ~= "" and marker or ref_str, marker)
        end
    end

    lines[#lines+1] = string.rep("─", 60)
    return table.concat(lines, "\n")
end

--- Analyze a grammar and return structured statistics.
---
--- @param  grammar  any  Grammar_obj or Builder.
--- @return table  { n_rules, root, unreferenced, recursive, gbnf_length }
function debug_m.analyze(grammar)
    local b = grammar._builder or grammar
    if not b or not b._rules then
        return { n_rules = 0, root = nil, unreferenced = {}, recursive = {} }
    end

    local root       = b._root or "root"
    local ref_counts = build_ref_counts(b._rules)

    local unreferenced = {}
    for _, r in ipairs(b._rules) do
        if r.name ~= root and (ref_counts[r.name] or 0) == 0 then
            unreferenced[#unreferenced+1] = r.name
        end
    end

    local recursive = {}
    for _, r in ipairs(b._rules) do
        local self_counts = {}
        collect_refs(r.body, self_counts)
        if (self_counts[r.name] or 0) > 0 then
            recursive[#recursive+1] = r.name
        end
    end

    local gbnf = b:compile()
    return {
        n_rules      = #b._rules,
        root         = root,
        unreferenced = unreferenced,
        recursive    = recursive,
        gbnf_length  = #gbnf,
    }
end

--- Compare two grammars and show what changed.
---
--- @param  g1  any  Original grammar.
--- @param  g2  any  Updated grammar.
--- @return string  Diff-style output.
function debug_m.diff(g1, g2)
    local b1 = g1._builder or g1
    local b2 = g2._builder or g2

    local function index_rules(rules)
        local idx = {}
        for _, r in ipairs(rules or {}) do idx[r.name] = r end
        return idx
    end

    local idx1 = index_rules(b1._rules)
    local idx2 = index_rules(b2._rules)

    local lines = { "Grammar diff:" }

    local added = {}
    for name in pairs(idx2) do
        if not idx1[name] then added[#added+1] = name end
    end
    table.sort(added)
    for _, name in ipairs(added) do lines[#lines+1] = "+ " .. name .. " (added)" end

    local removed = {}
    for name in pairs(idx1) do
        if not idx2[name] then removed[#removed+1] = name end
    end
    table.sort(removed)
    for _, name in ipairs(removed) do lines[#lines+1] = "- " .. name .. " (removed)" end

    local compiler_m = require "ion7.grammar.ast.compiler"
    local changed = {}
    for name, r1 in pairs(idx1) do
        local r2 = idx2[name]
        if r2 then
            local s1 = compiler_m.compile({ r1 }, name, false)
            local s2 = compiler_m.compile({ r2 }, name, false)
            if s1 ~= s2 then changed[#changed+1] = name end
        end
    end
    table.sort(changed)
    for _, name in ipairs(changed) do lines[#lines+1] = "~ " .. name .. " (changed)" end

    if #lines == 1 then lines[#lines+1] = "  (no changes)" end
    return table.concat(lines, "\n")
end

--- Generate an ASCII tree representation of grammar rule dependencies.
--- @param  grammar  any
--- @param  root     string?  Root rule (default: grammar's root or "root").
--- @return string
function debug_m.tree(grammar, root)
    local b = grammar._builder or grammar
    if not b or not b._rules then return "(empty)" end
    root = root or b._root or "root"

    local by_name = {}
    for _, r in ipairs(b._rules) do by_name[r.name] = r end

    local function get_refs(rule_name)
        local rule = by_name[rule_name]
        if not rule then return {} end
        local seen = {}
        local refs = {}
        local function walk(node)
            if not node then return end
            if node.kind == "ref" and node.name ~= rule_name then
                if not seen[node.name] then
                    seen[node.name] = true
                    refs[#refs+1] = node.name
                end
            elseif node.items then
                for _, item in ipairs(node.items) do walk(item) end
            elseif node.node then
                walk(node.node)
            end
        end
        walk(rule.body)
        return refs
    end

    local lines = {}
    local visited = {}
    local function render(name, prefix, is_last)
        if visited[name] then
            lines[#lines+1] = prefix .. (is_last and "└─ " or "├─ ") .. name .. " (↑ recursive)"
            return
        end
        visited[name] = true
        lines[#lines+1] = prefix .. (is_last and "└─ " or "├─ ") .. name
        local refs = get_refs(name)
        for i, ref in ipairs(refs) do
            local child_last   = (i == #refs)
            local child_prefix = prefix .. (is_last and "   " or "│  ")
            render(ref, child_prefix, child_last)
        end
    end

    lines[#lines+1] = root
    local refs = get_refs(root)
    for i, ref in ipairs(refs) do
        render(ref, "", i == #refs)
    end
    return table.concat(lines, "\n")
end

return debug_m
