--- @module ion7.grammar.ast.walk
--- SPDX-License-Identifier: MIT
--- AST traversal utilities shared across ion7-grammar modules.
---
--- Centralises the two walk patterns used by `debug.lua` (ref counting)
--- and `grammar_obj.lua` (first-set computation for `trigger_words`).
--- Internal module — not part of the public `Grammar.*` API.
---
--- @author Ion7-Labs
--- @version 0.1.0

local walk = {}

-- ── Reference counting ────────────────────────────────────────────────────────

--- Walk an AST node and accumulate ref-name counts into `counts`.
--- @param  node    node   AST node to walk.
--- @param  counts  table  { rule_name → count } accumulator (mutated in place).
function walk.collect_refs(node, counts)
    if not node then return end
    if node.kind == "ref" then
        counts[node.name] = (counts[node.name] or 0) + 1
    elseif node.items then
        for _, item in ipairs(node.items) do walk.collect_refs(item, counts) end
    elseif node.node then
        walk.collect_refs(node.node, counts)
    end
end

--- Build a { rule_name → total_ref_count } map across all rule bodies.
--- Counts how many times each rule name is referenced by other rules.
--- @param  rules  table  Array of { name, body } pairs (from Builder._rules).
--- @return table  { rule_name → count }
function walk.build_ref_counts(rules)
    local ref_counts = {}
    for _, r in ipairs(rules) do
        local counts = {}
        walk.collect_refs(r.body, counts)
        for name, n in pairs(counts) do
            ref_counts[name] = (ref_counts[name] or 0) + n
        end
    end
    return ref_counts
end

-- ── First-set computation (trigger_words) ─────────────────────────────────────

--- Recursively collect literal string prefixes that can start a valid match.
---
--- Only literal-initiated branches are collected; char-class branches (e.g.
--- [0-9]) are intentionally skipped because they would expand into too many
--- trigger strings to be useful for CRANE grammar_lazy activation.
---
--- @param  node       node    AST node to walk.
--- @param  rules_map  table   { rule_name → body } for ref resolution.
--- @param  visited    table   Set of already-visited rule names (cycle guard).
--- @param  acc        table   { prefix_string → true } accumulator (mutated).
--- @param  max_len    number  Maximum prefix length to collect.
function walk.first_literals(node, rules_map, visited, acc, max_len)
    if not node then return end
    local k = node.kind
    if k == "literal" then
        local s = node.value:sub(1, max_len)
        if #s > 0 then acc[s] = true end
    elseif k == "seq" then
        -- Only the first item of a sequence can start the match.
        if node.items and node.items[1] then
            walk.first_literals(node.items[1], rules_map, visited, acc, max_len)
        end
    elseif k == "alt" then
        -- Every alternative can independently start the match.
        for _, child in ipairs(node.items or {}) do
            walk.first_literals(child, rules_map, visited, acc, max_len)
        end
    elseif k == "rep" then
        -- Only include when at least one repetition is required (min >= 1).
        if (node.min or 0) >= 1 then
            walk.first_literals(node.node, rules_map, visited, acc, max_len)
        end
    elseif k == "ref" then
        local name = node.name
        if not visited[name] and rules_map[name] then
            visited[name] = true
            walk.first_literals(rules_map[name], rules_map, visited, acc, max_len)
        end
    elseif k == "group" then
        walk.first_literals(node.node, rules_map, visited, acc, max_len)
    end
    -- char nodes: too broad to enumerate as trigger prefixes — skip.
end

return walk
