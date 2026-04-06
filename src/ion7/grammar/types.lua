--- @module ion7.grammar.types
--- SPDX-License-Identifier: MIT
--- Lua type annotations → GBNF grammars.
---
--- Converts simple Lua type descriptions into grammars without having
--- to write JSON Schema or GBNF by hand. Designed for tool-calling and
--- structured output in agentic applications.
---
--- Type syntax:
---   "string"              Any JSON string
---   "number"              Any JSON number
---   "integer"             Any JSON integer
---   "boolean"             true | false
---   "null"                null
---   { "string" }          Array of strings
---   { "integer" }         Array of integers
---   { key = "type", ... } Object with typed fields
---   { key = { "type" } }  Object with array-typed fields
---   { key = { a="t" } }   Nested objects
---   "string?"             Optional string (null | string)
---
--- @usage
---   local Types = require "ion7.grammar.types"
---
---   -- Simple struct
---   local g = Types.from_type({
---       name    = "string",
---       age     = "integer",
---       active  = "boolean",
---       tags    = { "string" },
---   })
---   print(g:to_gbnf())
---
---   -- Nested
---   local g = Types.from_type({
---       user = {
---           id    = "integer",
---           email = "string",
---       },
---       count = "integer",
---   })
---
---   -- With required fields (all are required by default)
---   local g = Types.from_type({
---       name   = "string",
---       ["age?"] = "integer",   -- optional field (key ends with ?)
---   })
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast     = require "ion7.grammar.ast"
local Builder = require "ion7.grammar.builder"
local json_m  = require "ion7.grammar.json"

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
--- @error  If a primitive type string is unrecognised.
--- @error  If typ is neither a string nor a table.
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
        error("[ion7.grammar.types] unknown primitive type: '" .. typ .. "'")
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
                local optional   = false
                -- Support "field?" syntax for optional fields
                local base_key = k:match("^(.-)%?$")
                if base_key then
                    field_name = base_key
                    optional   = true
                end
                props[field_name] = Types.to_schema(v)
                if not optional then
                    required[#required + 1] = field_name
                end
            end
        end
        -- Sort required for deterministic output
        table.sort(required)
        return {
            type       = "object",
            properties = props,
            required   = #required > 0 and required or nil,
        }
    end

    error("[ion7.grammar.types] unsupported type annotation: " .. type(typ))
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Build a Grammar from a Lua type annotation.
---
--- @param  typ   string|table  Type annotation (see module docs).
--- @param  root  string?       Root rule name (default: "root").
--- @return Grammar_obj
---
--- @usage
---   local g = Types.from_type({
---       name    = "string",
---       age     = "integer",
---       ["score?"] = "number",   -- optional
---       tags    = { "string" },  -- array of strings
---   })
---   -- Use with ion7-core:
---   local sampler = ion7.Sampler.chain()
---       :grammar(g:to_gbnf(), "root", vocab._ptr)
---       :temperature(0.1)
---       :dist()
---       :build(vocab)
function Types.from_type(typ, root)
    root = root or "root"
    local schema = Types.to_schema(typ)
    local Grammar_init = require "ion7.grammar"
    return Grammar_init.from_json_schema(schema, root)
end

--- Build a Grammar for a named function signature.
---
--- Generates a JSON object grammar for calling a function with typed args.
--- Equivalent to `from_type` but documents the semantic intent.
---
--- @param  name    string  Function/tool name (for documentation only).
--- @param  params  table   Parameter type annotations { param = type, ... }.
--- @param  root    string? Root rule name (default: "root").
--- @return Grammar_obj
---
--- @usage
---   local g = Types.from_function("search", {
---       query  = "string",
---       limit  = "integer",
---       ["offset?"] = "integer",
---   })
function Types.from_function(name, params, root)
    assert(type(name) == "string",
        "[ion7.grammar.types] function name must be a string")
    return Types.from_type(params, root)
end

return Types
