--- @module ion7.grammar.dynamic
--- SPDX-License-Identifier: AGPL-3.0-or-later
--- Input-dependent grammars - build grammars from runtime data.
---
--- The core problem with static grammars: if you write a grammar for SQL,
--- the model can still hallucinate `SELECT * FROM fake_table`. The grammar
--- only enforces SQL *syntax*, not *semantic validity* against your schema.
---
--- Dynamic grammars solve this by building the GBNF from your actual data
--- at runtime. The model becomes physically incapable of generating a table
--- name, function name, or enum value that doesn't exist in your dataset.
---
--- @usage
---   -- SQL: only real table/column names allowed
---   local g = Dynamic.from_values({
---       tables  = { "users", "orders", "products" },
---       columns = { "id", "name", "email", "created_at" },
---   })
---
---   -- Function calling: only registered tool names
---   local g = Dynamic.from_enum("tool-name", tool_registry:names())
---
---   -- Constrained identifier from regex + whitelist
---   local g = Dynamic.from_values_with_pattern(
---       { "GET", "POST", "PUT", "DELETE" },
---       "[A-Z]+"
---   )
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast      = require "ion7.grammar.ast"
local Builder  = require "ion7.grammar.builder"
local compiler = require "ion7.grammar.compiler"

local Dynamic = {}

--- Build a grammar that matches exactly one value from a list.
---
--- Deduplicates the list and sorts by length descending so that longer
--- matches are tried first, preventing prefix ambiguity (e.g. "GET"
--- shadowing "GETTER"). The resulting builder contains a single rule
--- whose name is `rule_name`.
---
--- @param  rule_name  string  Name for the generated GBNF rule.
--- @param  values     table   Non-empty array of string values to allow.
--- @return Builder  Builder with one rule named `rule_name`.
--- @error  If `rule_name` is not a string.
--- @error  If `values` is not a non-empty table.
function Dynamic.from_enum(rule_name, values)
    assert(type(rule_name) == "string", "[ion7.grammar.dynamic] rule_name must be a string")
    assert(type(values) == "table" and #values > 0,
        "[ion7.grammar.dynamic] values must be a non-empty array")

    -- Sort longest-first to avoid prefix ambiguity
    local sorted = {}
    for _, v in ipairs(values) do sorted[#sorted+1] = v end
    table.sort(sorted, function(a, b) return #a > #b end)

    -- Deduplicate
    local seen = {}
    local unique = {}
    for _, v in ipairs(sorted) do
        if not seen[v] then seen[v] = true; unique[#unique+1] = v end
    end

    local alts = {}
    for _, v in ipairs(unique) do
        alts[#alts+1] = ast.literal(v)
    end

    local body = #alts == 1 and alts[1] or ast.alt(table.unpack(alts))
    return Builder.new({ root = rule_name }):rule(rule_name, body)
end

--- Build a grammar from a table of named value sets.
---
--- Each key in `schema` becomes a named rule containing an alternation
--- of all its values. Useful for SQL schemas, API parameter sets, etc.
--- Rules are added to the builder via from_enum, so each rule also
--- benefits from deduplication and longest-first ordering.
---
--- @param  schema  table  Map of { rule_name = { value1, value2, ... }, ... }.
--- @param  opts    table?
---   opts.root  string?  Name of the explicit root rule (default: nil - first key used by Builder).
--- @return Builder  Builder containing one rule per schema key.
---
--- @usage
---   local b = Dynamic.from_schema({
---       table_name  = { "users", "orders", "products" },
---       column_name = { "id", "name", "email", "created_at" },
---       operator    = { "=", "!=", "<", ">", "<=", ">=" },
---   })
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
--- Unlike from_enum (which matches raw values), this wraps each value
--- in JSON string quotes so the model must emit `"value"` literally.
--- Useful for JSON field values and typed enum properties in JSON objects.
--- Values are JSON-escaped (backslashes and double-quotes are escaped).
---
--- @param  rule_name  string  Rule name for the generated GBNF rule.
--- @param  values     table   Non-empty array of unquoted string values.
--- @return Builder  Builder with one rule named `rule_name`.
--- @error  If `values` is empty.
function Dynamic.from_json_enum(rule_name, values)
    assert(#values > 0, "[ion7.grammar.dynamic] values must be non-empty")
    local alts = {}
    local seen = {}
    for _, v in ipairs(values) do
        if not seen[v] then
            seen[v] = true
            -- Escape value for JSON string
            local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"')
            alts[#alts+1] = ast.literal('"' .. escaped .. '"')
        end
    end
    -- Longest first
    table.sort(alts, function(a, b) return #a.value > #b.value end)
    local body = #alts == 1 and alts[1] or ast.alt(table.unpack(alts))
    return Builder.new({ root = rule_name }):rule(rule_name, body)
end

--- Build a grammar that restricts a string to a pattern AND a whitelist.
---
--- Combines structural constraint (regex) with semantic constraint (values).
--- The grammar will only accept strings that both match the pattern AND
--- appear in the whitelist.
---
--- Implementation note: GBNF cannot express the intersection of a regex and
--- a whitelist directly. This function generates an explicit alternation over
--- the whitelisted values (the stronger semantic constraint). The `_pattern`
--- parameter documents the intended structural constraint for human readers
--- but is not applied in the generated GBNF. If pattern filtering is required
--- at runtime, use Backtrack:constrain() with a Lua pattern validator.
---
--- @param  rule_name  string  Name for the generated GBNF rule.
--- @param  values     table   Allowed string values (whitelist).
--- @param  _pattern   string? Regex pattern (documentation only; not applied).
--- @return Builder  Builder containing only the whitelist alternation.
function Dynamic.from_values_with_pattern(rule_name, values, _pattern)
    -- In GBNF, we can't intersect a regex and a whitelist.
    -- The whitelist is the strongest constraint - use it directly.
    -- The pattern parameter documents the intended structure.
    return Dynamic.from_enum(rule_name, values)
end

--- Build a function-call grammar from a registry of tool definitions.
---
--- Generates a grammar for JSON tool calls of the form:
---   { "name": "<tool_name>", "arguments": { ... schema ... } }
---
--- Each tool produces a separate named rule (`tool-<name>`). All tools are
--- combined in an alternation under a `tool-call` root rule. A `root` alias
--- pointing to `tool-call` is also added so the grammar integrates with the
--- standard Grammar_obj API.
--- Internal argument schemas are expanded via json_m.to_rules so that complex
--- JSON Schema (nested objects, arrays, oneOf) is fully supported.
---
--- @param  tools  table  Non-empty array of tool definition tables, each with:
---   tool.name    string  Tool name (used verbatim as the "name" JSON value).
---   tool.schema  table?  JSON Schema for the "arguments" object (default: any object).
--- @return Builder  Builder with rules: `ws`, per-tool rules, `tool-call`, `root`.
--- @error  If `tools` is not a non-empty table.
--- @usage
---   local g = Dynamic.from_tools({
---       { name = "search_web",  schema = { type="object", properties={query={type="string"}}, required={"query"} } },
---       { name = "read_file",   schema = { type="object", properties={path={type="string"}},  required={"path"} } },
---   })
function Dynamic.from_tools(tools)
    assert(type(tools) == "table" and #tools > 0,
        "[ion7.grammar.dynamic] tools must be a non-empty array")

    local json_m = require "ion7.grammar.json"
    local b = Builder.new({ root = "tool-call" })

    -- Add ws rule
    b:rule("ws", ast.star(ast.char(" \\t\\n\\r")))

    -- Build per-tool rules
    local tool_alts = {}
    for _, tool in ipairs(tools) do
        local tname = tool.name
        local rule_name = "tool-" .. tname:gsub("[^%a%d%-]", "-")

        -- Arguments schema → GBNF rules
        local args_schema = tool.schema or { type = "object" }
        local args_rules, args_root = json_m.to_rules(args_schema, rule_name .. "-args")
        for _, r in ipairs(args_rules) do
            if not b._names[r.name] then b:rule(r.name, r.body) end
        end

        -- { "name": "tool-name", "arguments": { ... } }
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
    -- Add "root" alias so all Grammar constructors expose the same root name
    b:rule("root", ast.ref("tool-call"))
    b:root("root")
    return b
end

return Dynamic
