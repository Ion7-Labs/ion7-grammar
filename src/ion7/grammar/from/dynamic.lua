--- @module ion7.grammar.from.dynamic
--- SPDX-License-Identifier: MIT
--- Runtime-data grammars — build grammars from live values.
---
--- Dynamic grammars close the semantic gap of static grammars: instead of
--- only enforcing syntax, the model becomes physically incapable of
--- generating a table name, function name, or enum value that does not
--- exist in your actual dataset.
---
--- @usage
---   local Dynamic = require "ion7.grammar.from.dynamic"
---
---   -- Only allow values that exist in the DB right now
---   local b = Dynamic.from_enum("table-name", db:get_table_names())
---   local gbnf = b:compile()
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast     = require "ion7.grammar.ast"
local Builder = require "ion7.grammar.ast.builder"

local Dynamic = {}

--- Build a grammar that matches exactly one value from a list.
---
--- Deduplicates and sorts longest-first to prevent prefix ambiguity.
---
--- @param  rule_name  string  Name for the generated GBNF rule.
--- @param  values     table   Non-empty array of string values to allow.
--- @return Builder
function Dynamic.from_enum(rule_name, values)
    assert(type(rule_name) == "string",
        "[ion7.grammar.from.dynamic] rule_name must be a string")
    assert(type(values) == "table" and #values > 0,
        "[ion7.grammar.from.dynamic] values must be a non-empty array")

    local sorted = {}
    for _, v in ipairs(values) do sorted[#sorted+1] = v end
    table.sort(sorted, function(a, b) return #a > #b end)

    local seen = {}
    local unique = {}
    for _, v in ipairs(sorted) do
        if not seen[v] then seen[v] = true; unique[#unique+1] = v end
    end

    local alts = {}
    for _, v in ipairs(unique) do alts[#alts+1] = ast.literal(v) end

    local body = #alts == 1 and alts[1] or ast.alt(table.unpack(alts))
    return Builder.new({ root = rule_name }):rule(rule_name, body)
end

--- Build a grammar from a table of named value sets.
---
--- @param  schema  table  Map of { rule_name = { value1, ... }, ... }.
--- @param  opts    table?
---   opts.root  string?  Explicit root rule name.
--- @return Builder
function Dynamic.from_schema(schema, opts)
    opts = opts or {}
    local b = Builder.new({ root = opts.root })
    for rule_name, values in pairs(schema) do
        local sub = Dynamic.from_enum(rule_name, values)
        b:merge(sub)
    end
    return b
end

--- Build a grammar that matches a quoted JSON string from a whitelist.
---
--- @param  rule_name  string  Rule name for the generated GBNF rule.
--- @param  values     table   Non-empty array of unquoted string values.
--- @return Builder
function Dynamic.from_json_enum(rule_name, values)
    assert(#values > 0, "[ion7.grammar.from.dynamic] values must be non-empty")
    local alts = {}
    local seen = {}
    for _, v in ipairs(values) do
        if not seen[v] then
            seen[v] = true
            local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"')
            alts[#alts+1] = ast.literal('"' .. escaped .. '"')
        end
    end
    table.sort(alts, function(a, b) return #a.value > #b.value end)
    local body = #alts == 1 and alts[1] or ast.alt(table.unpack(alts))
    return Builder.new({ root = rule_name }):rule(rule_name, body)
end

--- Build a grammar restricted to a whitelist (pattern param is documentation only).
---
--- GBNF cannot express the intersection of a regex and a whitelist directly.
--- The whitelist is the stronger constraint and is used directly.
---
--- @param  rule_name  string  Name for the generated GBNF rule.
--- @param  values     table   Allowed string values.
--- @param  _pattern   string? Regex pattern (documentation only; not applied).
--- @return Builder
function Dynamic.from_values_with_pattern(rule_name, values, _pattern)
    return Dynamic.from_enum(rule_name, values)
end

--- Build a function-call grammar from a registry of tool definitions.
---
--- Each tool produces a JSON object: { "name": "...", "arguments": { ... } }.
--- Tools are combined in an alternation under a `tool-call` root rule.
---
--- @param  tools  table  Non-empty array of { name, schema? } tables.
--- @return Builder
function Dynamic.from_tools(tools)
    assert(type(tools) == "table" and #tools > 0,
        "[ion7.grammar.from.dynamic] tools must be a non-empty array")

    local json_m = require "ion7.grammar.from.json"
    local b = Builder.new({ root = "tool-call" })

    b:rule("ws", ast.star(ast.char(" \\t\\n\\r")))

    local tool_alts = {}
    for _, tool in ipairs(tools) do
        local tname     = tool.name
        local rule_name = "tool-" .. tname:gsub("[^%a%d%-]", "-")

        local args_schema = tool.schema or { type = "object" }
        local args_rules, args_root = json_m.to_rules(args_schema, rule_name .. "-args")
        for _, r in ipairs(args_rules) do
            if not b._names[r.name] then b:rule(r.name, r.body) end
        end

        local tool_body = ast.seq(
            ast.literal("{"),
            ast.ref("ws"),
            ast.literal('"name"'),
            ast.ref("ws"),
            ast.literal(":"),
            ast.ref("ws"),
            ast.literal('"' .. tname:gsub('"', '\\"') .. '"'),
            ast.literal(","),
            ast.ref("ws"),
            ast.literal('"arguments"'),
            ast.ref("ws"),
            ast.literal(":"),
            ast.ref("ws"),
            ast.ref(args_root),
            ast.ref("ws"),
            ast.literal("}")
        )
        b:rule(rule_name, tool_body)
        tool_alts[#tool_alts+1] = ast.ref(rule_name)
    end

    local root_body = #tool_alts == 1 and tool_alts[1]
                      or ast.alt(table.unpack(tool_alts))
    b:rule("tool-call", root_body)
    b:rule("root", ast.ref("tool-call"))
    b:root("root")
    return b
end

return Dynamic
