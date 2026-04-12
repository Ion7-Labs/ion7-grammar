--- @module ion7.grammar.from.types
--- SPDX-License-Identifier: MIT
--- Lua type annotations → GBNF grammars.
---
--- Converts simple Lua type descriptions into grammars without writing
--- JSON Schema or GBNF by hand. Designed for tool-calling and structured
--- output in agentic applications.
---
--- Type syntax:
---   `"string"`              Any JSON string
---   `"number"`              Any JSON number
---   `"integer"`             Any JSON integer
---   `"boolean"`             `true | false`
---   `"null"`                `null`
---   `"any"`                 Unconstrained
---   `"T?"`                  Optional — `null | T`
---   `{ "T" }`               Array of T
---   `{ key = "T", ... }`    Object with typed fields (all required)
---   `{ ["key?"] = "T" }`    Optional field (key ending with `?`)
---   `{ key = { "T" } }`     Field whose value is an array
---
--- @usage
---   local Types = require "ion7.grammar.from.types"
---   local b = Types.from_type({ name = "string", age = "integer?" })
---   print(b:compile())
---
--- @author Ion7-Labs
--- @version 0.1.0

local json_m  = require "ion7.grammar.from.json"
local Builder = require "ion7.grammar.ast.builder"

local Types = {}

-- ── Type → JSON Schema converter ─────────────────────────────────────────────

--- Convert a Lua type annotation to a JSON Schema table.
---
--- Maps the simplified ion7 type syntax to a JSON Schema draft-07 subset
--- that can be fed into the full JSON Schema → GBNF pipeline.
--- Handles primitives, optional markers (?), arrays, and nested objects.
---
--- Type string values:
---   "string"   → { type = "string" }
---   "number"   → { type = "number" }
---   "integer"  → { type = "integer" }
---   "boolean"  → { type = "boolean" }
---   "null"     → { type = "null" }
---   "any"      → {} (unconstrained)
---   "T?"       → { oneOf = { to_schema("T"), { type="null" } } }
---
--- Table values:
---   { "T" }              → array items schema (single-element array)
---   { key = "T", ... }  → object with typed properties
---   { ["key?"] = "T" }  → object with optional field (key ending with ?)
---
--- @param  typ  string|table  Type annotation in ion7 type syntax.
--- @return table  JSON Schema draft-07 compatible table.
function Types.to_schema(typ)
    if type(typ) == "string" then
        -- Strip optional marker
        local base, optional = typ:match("^(.-)(%?)$")
        if optional then
            return { oneOf = { Types.to_schema(base), { type = "null" } } }
        end
        -- Primitive types
        if typ == "string"  then return { type = "string" }  end
        if typ == "number"  then return { type = "number" }  end
        if typ == "integer" then return { type = "integer" } end
        if typ == "boolean" then return { type = "boolean" } end
        if typ == "null"    then return { type = "null" }    end
        if typ == "any"     then return {}                   end
        error("[ion7.grammar.from.types] unknown primitive type: '" .. typ .. "'")
    end

    if type(typ) == "table" then
        -- Array: { "string" } or { "integer" } etc.
        if #typ == 1 and type(typ[1]) == "string" or
           #typ == 1 and type(typ[1]) == "table" then
            return {
                type  = "array",
                items = Types.to_schema(typ[1]),
            }
        end

        -- Object: { key = type, ... }
        local props    = {}
        local required = {}
        for k, v in pairs(typ) do
            if type(k) == "string" then
                local field_name = k
                local is_optional = false
                local base_key = k:match("^(.-)%?$")
                if base_key then
                    field_name   = base_key
                    is_optional  = true
                end
                props[field_name] = Types.to_schema(v)
                if not is_optional then
                    required[#required + 1] = field_name
                end
            end
        end
        -- Sort required for deterministic output (stable KV prefix cache)
        table.sort(required)
        return {
            type       = "object",
            properties = props,
            required   = #required > 0 and required or nil,
        }
    end

    error("[ion7.grammar.from.types] unsupported type annotation: " .. type(typ))
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Build a Builder from a Lua type annotation.
---
--- Avoids the circular dep of calling Grammar.from_json_schema() by going
--- directly to json_m.to_rules() + Builder — same pipeline, no middle layer.
---
--- @param  typ   string|table  Type annotation (see module docs).
--- @param  root  string?       Root rule name (default: "root").
--- @return Builder
function Types.from_type(typ, root)
    root = root or "root"
    local schema = Types.to_schema(typ)
    local rules, root_name = json_m.to_rules(schema, root)
    local b = Builder.new({ root = root_name })
    for _, r in ipairs(rules) do b:rule(r.name, r.body) end
    return b
end

--- Build a Builder for a named function signature.
---
--- Generates a JSON object grammar for calling a function with typed args.
--- Equivalent to `from_type` but documents the semantic intent.
---
--- @param  name    string  Function/tool name (for documentation only).
--- @param  params  table   Parameter type annotations { param = type, ... }.
--- @param  root    string? Root rule name (default: "root").
--- @return Builder
function Types.from_function(name, params, root)
    assert(type(name) == "string",
        "[ion7.grammar.from.types] function name must be a string")
    return Types.from_type(params, root)
end

return Types
