--- SPDX-License-Identifier: MIT
--- JSON Schema → GBNF public API.
---
--- Converts a JSON Schema (Lua table) to a set of GBNF rules.
--- The resulting grammar guarantees syntactically valid JSON that
--- matches the schema — no post-processing or validation needed.
---
--- Supported JSON Schema keywords:
---   type, properties, required, additionalProperties,
---   items, minItems, maxItems, enum, oneOf, anyOf, allOf,
---   minimum/maximum, minLength/maxLength, pattern, const,
---   $ref (local only, e.g. "#/$defs/Foo"), $defs / definitions
---
--- @author Ion7-Labs

local Converter = require "ion7.grammar.from.json.converter"
local ast       = require "ion7.grammar.ast"

local json_mod = {}

--- Sentinel for JSON null in Lua (Lua has no null value).
json_mod.null = Converter.null

--- Convert a JSON Schema to GBNF rules (as an array for Builder:merge).
---
--- @param  schema  table   JSON Schema as Lua table.
--- @param  root    string? Root rule name (default: "root").
--- @return table   Array of { name, body } rules.
--- @return string  Root rule name.
function json_mod.to_rules(schema, root)
    root = root or "root"
    local conv = Converter.new(schema)

    -- Process $defs / definitions first
    for _, dkey in ipairs({ "$defs", "definitions" }) do
        if schema[dkey] then
            for defname, defschema in pairs(schema[dkey]) do
                local rule_name = conv:convert(defschema, defname)
                if rule_name ~= defname then
                    conv:add_rule(defname, ast.ref(rule_name))
                end
            end
        end
    end

    local result_rule = conv:convert(schema, root)

    if not conv._names["ws"] then
        conv:add_rule("ws", ast.star(ast.char(" \\t\\n")))
    end

    if result_rule ~= root then
        conv:add_rule(root, ast.ref(result_rule))
    end

    return conv._rules, root
end

--- Convert a JSON Schema directly to a GBNF string.
---
--- @param  schema  table   JSON Schema as Lua table.
--- @param  root    string? Root rule name (default: "root").
--- @return string  GBNF string.
function json_mod.to_gbnf(schema, root)
    root = root or "root"
    local rules, root_name = json_mod.to_rules(schema, root)
    local compiler = require "ion7.grammar.ast.compiler"
    return compiler.compile(rules, root_name, false)
end

return json_mod
