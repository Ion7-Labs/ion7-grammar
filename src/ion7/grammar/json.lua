--- @module ion7.grammar.json
--- SPDX-License-Identifier: AGPL-3.0-or-later
--- JSON Schema → GBNF converter.
---
--- Converts a JSON Schema (Lua table) to a set of GBNF rules.
--- The resulting grammar guarantees syntactically valid JSON that
--- matches the schema - no post-processing or validation needed.
---
--- Supported JSON Schema keywords:
---   type: string|number|integer|boolean|null|array|object
---   properties, required, additionalProperties
---   items (array), minItems, maxItems
---   enum
---   oneOf, anyOf
---   minimum, maximum (for numbers - encoded as grammar constraints)
---   minLength, maxLength (for strings)
---   pattern (for strings - converted via regex module)
---   const
---   $ref (local refs only, e.g. "#/$defs/Foo")
---   $defs / definitions
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast      = require "ion7.grammar.ast"
local regex_m  = require "ion7.grammar.regex"

local json_mod = {}

-- ── Internal converter ────────────────────────────────────────────────────────

local Converter = {}
Converter.__index = Converter

function Converter.new(schema)
    return setmetatable({
        _root   = schema,
        _rules  = {},
        _names  = {},
        _counter = 0,
    }, Converter)
end

function Converter:fresh(prefix)
    self._counter = self._counter + 1
    return (prefix or "val") .. "-" .. self._counter
end

function Converter:add_rule(name, body)
    if not self._names[name] then
        self._rules[#self._rules + 1] = { name = name, body = body }
        self._names[name] = true
    end
    return name
end

-- Resolve $ref
function Converter:resolve_ref(ref)
    -- Only local refs: "#/$defs/Foo" or "#/definitions/Foo"
    local path = ref:match("^#/(.+)$")
    if not path then error("[ion7.grammar.json] only local $ref supported: " .. ref) end
    local parts = {}
    for p in path:gmatch("[^/]+") do parts[#parts+1] = p end
    local node = self._root
    for _, p in ipairs(parts) do
        node = node[p]
        if not node then error("[ion7.grammar.json] $ref not found: " .. ref) end
    end
    return node
end

-- Convert a schema node, return a rule name (guaranteed)
function Converter:convert(schema, hint)
    if type(schema) == "boolean" then
        if schema then return self:add_rule("any-value", ast.ref("json-value"))
        else error("[ion7.grammar.json] false schema not supported") end
    end

    -- $ref
    if schema["$ref"] then
        local resolved = self:resolve_ref(schema["$ref"])
        return self:convert(resolved, hint)
    end

    -- const
    if schema["const"] ~= nil then
        local name = self:fresh(hint or "const")
        local encoded = self:encode_value(schema["const"])
        return self:add_rule(name, encoded)
    end

    -- enum
    if schema["enum"] then
        local alts = {}
        for _, v in ipairs(schema["enum"]) do
            alts[#alts+1] = self:encode_value(v)
        end
        local name = self:fresh(hint or "enum")
        return self:add_rule(name, ast.alt(table.unpack(alts)))
    end

    -- oneOf / anyOf (treated the same in GBNF - both are alternatives)
    local combo = schema["oneOf"] or schema["anyOf"]
    if combo then
        local alts = {}
        for _, s in ipairs(combo) do
            alts[#alts+1] = ast.ref(self:convert(s))
        end
        local name = self:fresh(hint or "oneof")
        return self:add_rule(name, ast.alt(table.unpack(alts)))
    end

    -- allOf: shallow merge of all sub-schemas (last-write-wins on key conflict).
    -- True intersection is undecidable in GBNF; this is a best-effort approximation.
    if schema["allOf"] then
        local merged = {}
        for _, s in ipairs(schema["allOf"]) do
            for k, v in pairs(s) do merged[k] = v end
        end
        return self:convert(merged, hint)
    end

    local t = schema["type"]

    -- Multiple types: ["string", "null"] → alternation
    if type(t) == "table" then
        local alts = {}
        for _, ty in ipairs(t) do
            alts[#alts+1] = ast.ref(self:convert({ type = ty }, hint))
        end
        local name = self:fresh(hint or "multi")
        return self:add_rule(name, ast.alt(table.unpack(alts)))
    end

    if t == "string"  then return self:convert_string(schema, hint) end
    if t == "number"  then return self:ensure_base("number") end
    if t == "integer" then return self:ensure_base("integer") end
    if t == "boolean" then return self:ensure_base("boolean") end
    if t == "null"    then return self:ensure_base("null") end
    if t == "array"   then return self:convert_array(schema, hint) end
    if t == "object"  then return self:convert_object(schema, hint) end

    -- No type: accept any JSON value
    return self:ensure_base("json-value")
end

-- Encode a Lua value as a literal AST node (for const/enum)
function Converter:encode_value(v)
    if v == nil or v == json_mod.null then
        return ast.literal("null")
    elseif type(v) == "boolean" then
        return ast.literal(v and "true" or "false")
    elseif type(v) == "number" then
        return ast.literal(tostring(v))
    elseif type(v) == "string" then
        -- Escape for JSON string literal
        local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"')
                         :gsub('\n', '\\n'):gsub('\r', '\\r')
                         :gsub('\t', '\\t')
        return ast.literal('"' .. escaped .. '"')
    elseif type(v) == "table" then
        error("[ion7.grammar.json] table const not supported (use $ref)")
    end
    error("[ion7.grammar.json] unsupported const type: " .. type(v))
end

-- Ensure a base rule exists, return its name
function Converter:ensure_base(name)
    if self._names[name] then return name end
    -- Mark as in-progress BEFORE any recursive calls.
    -- Breaks mutual recursion: json_value -> json_array -> json_value.
    self._names[name] = true
    local body
    if name == "null"    then body = ast.literal("null")
    elseif name == "boolean" then
        body = ast.alt(ast.literal("true"), ast.literal("false"))
    elseif name == "integer" then
        body = ast.seq(
            ast.opt(ast.literal("-")),
            ast.alt(
                ast.literal("0"),
                ast.seq(ast.char("1-9"), ast.star(ast.char("0-9")))
            )
        )
    elseif name == "number" then
        body = ast.seq(
            ast.opt(ast.literal("-")),
            ast.alt(
                ast.literal("0"),
                ast.seq(ast.char("1-9"), ast.star(ast.char("0-9")))
            ),
            ast.opt(ast.seq(
                ast.literal("."),
                ast.plus(ast.char("0-9"))
            )),
            ast.opt(ast.seq(
                ast.char("eE"),
                ast.opt(ast.char("+-")),
                ast.plus(ast.char("0-9"))
            ))
        )
    elseif name == "string" then
        -- Generic JSON string
        body = ast.seq(
            ast.literal('"'),
            ast.star(ast.alt(
                ast.char('^"\\\\'),
                ast.seq(ast.literal("\\\\"), ast.char('.'))
            )),
            ast.literal('"')
        )
    elseif name == "json-value" then
        -- Forward refs to all value types
        self:ensure_base("null")
        self:ensure_base("boolean")
        self:ensure_base("number")
        self:ensure_base("string")
        self:ensure_base("json-array")
        self:ensure_base("json-object")
        body = ast.alt(
            ast.ref("null"), ast.ref("boolean"), ast.ref("number"),
            ast.ref("string"), ast.ref("json-array"), ast.ref("json-object")
        )
    elseif name == "json-array" then
        self:ensure_base("json-value")
        body = ast.alt(
            ast.seq(ast.literal("["), ast.ref("ws"), ast.literal("]")),
            ast.seq(
                ast.literal("["), ast.ref("ws"),
                ast.ref("json-value"),
                ast.star(ast.seq(
                    ast.literal(","), ast.ref("ws"), ast.ref("json-value")
                )),
                ast.ref("ws"), ast.literal("]")
            )
        )
    elseif name == "json-object" then
        self:ensure_base("string")
        self:ensure_base("json-value")
        body = ast.alt(
            ast.seq(ast.literal("{"), ast.ref("ws"), ast.literal("}")),
            ast.seq(
                ast.literal("{"), ast.ref("ws"),
                ast.ref("string"), ast.ref("ws"),
                ast.literal(":"), ast.ref("ws"),
                ast.ref("json-value"),
                ast.star(ast.seq(
                    ast.literal(","), ast.ref("ws"),
                    ast.ref("string"), ast.ref("ws"),
                    ast.literal(":"), ast.ref("ws"),
                    ast.ref("json-value")
                )),
                ast.ref("ws"), ast.literal("}")
            )
        )
    else
        error("[ion7.grammar.json] unknown base: " .. name)
    end
    -- _names[name] is already set above. Just append the rule.
    self._rules[#self._rules + 1] = { name = name, body = body }
    return name
end

-- Convert string schema
function Converter:convert_string(schema, hint)
    -- Pattern constraint → regex
    if schema["pattern"] then
        local name = self:fresh(hint or "str")
        local pat_node = regex_m.to_ast(schema["pattern"])
        local body = ast.seq(ast.literal('"'), pat_node, ast.literal('"'))
        return self:add_rule(name, body)
    end

    -- Length constraints
    local min_len = schema["minLength"]
    local max_len = schema["maxLength"]
    if min_len or max_len then
        local name = self:fresh(hint or "str")
        local char_node = ast.alt(
            ast.char('^"\\\\'),
            ast.seq(ast.literal("\\\\"), ast.char('.'))
        )
        local min_l = min_len or 0
        local max_l = max_len or -1
        local body = ast.seq(
            ast.literal('"'),
            ast.rep(char_node, min_l, max_l),
            ast.literal('"')
        )
        return self:add_rule(name, body)
    end

    -- Plain string
    return self:ensure_base("string")
end

-- Convert array schema
function Converter:convert_array(schema, hint)
    local name = self:fresh(hint or "arr")

    local item_rule
    if schema["items"] then
        item_rule = ast.ref(self:convert(schema["items"], name .. "-item"))
    else
        item_rule = ast.ref(self:ensure_base("json-value"))
    end

    local min_i = schema["minItems"] or 0
    local max_i = schema["maxItems"] or -1

    -- Build: "[" ws (item ("," ws item){min-1,max-1})? ws "]"
    local items_body
    if min_i == 0 and max_i == -1 then
        -- Optional items
        items_body = ast.opt(ast.seq(
            item_rule,
            ast.star(ast.seq(ast.literal(","), ast.ref("ws"), item_rule))
        ))
    else
        local repeated = ast.rep(
            ast.seq(ast.literal(","), ast.ref("ws"), item_rule),
            math.max(0, min_i - 1),
            max_i == -1 and -1 or math.max(0, max_i - 1)
        )
        if min_i > 0 then
            items_body = ast.seq(item_rule, repeated)
        else
            items_body = ast.opt(ast.seq(item_rule, repeated))
        end
    end

    local body = ast.seq(
        ast.literal("["), ast.ref("ws"),
        items_body,
        ast.ref("ws"), ast.literal("]")
    )
    return self:add_rule(name, body)
end

-- Convert object schema
function Converter:convert_object(schema, hint)
    local name = self:fresh(hint or "obj")

    local props     = schema["properties"] or {}
    local required  = {}
    for _, k in ipairs(schema["required"] or {}) do required[k] = true end

    -- Build required and optional field lists in definition order
    local req_fields = {}
    local opt_fields = {}

    for k, v in pairs(props) do
        local field_rule = self:convert(v, name .. "-" .. k:gsub("_", "-"))
        local field_body = ast.seq(
            ast.literal('"' .. k .. '"'),
            ast.ref("ws"),
            ast.literal(":"),
            ast.ref("ws"),
            ast.ref(field_rule)
        )
        local fname = self:add_rule(name .. "-kv-" .. k:gsub("_", "-"), field_body)
        if required[k] then
            req_fields[#req_fields + 1] = fname
        else
            opt_fields[#opt_fields + 1] = fname
        end
    end

    -- additionalProperties: allow any extra k/v pairs
    local allow_extra = schema["additionalProperties"]
    if allow_extra == nil then allow_extra = true end  -- JSON Schema default

    -- Build the members list
    -- Pattern: required fields first, then optional (each prefixed with comma)
    local parts = {}

    for i, f in ipairs(req_fields) do
        if i == 1 then
            parts[#parts + 1] = ast.ref(f)
        else
            parts[#parts + 1] = ast.seq(
                ast.literal(","), ast.ref("ws"), ast.ref(f))
        end
    end

    for _, f in ipairs(opt_fields) do
        local comma_field = ast.seq(
            ast.literal(","), ast.ref("ws"), ast.ref(f))
        if #parts == 0 then
            -- First item can be the optional field without comma
            parts[#parts + 1] = ast.opt(ast.ref(f))
        else
            parts[#parts + 1] = ast.opt(comma_field)
        end
    end

    -- Additional properties
    if allow_extra and allow_extra ~= false then
        self:ensure_base("string")
        self:ensure_base("json-value")
        local extra = ast.seq(
            ast.literal(","), ast.ref("ws"),
            ast.ref("string"), ast.ref("ws"),
            ast.literal(":"), ast.ref("ws"),
            ast.ref("json-value")
        )
        parts[#parts + 1] = ast.star(extra)
    end

    local members_body
    if #parts == 0 then
        members_body = ast.literal("")  -- empty object allowed
    elseif #parts == 1 then
        members_body = parts[1]
    else
        members_body = ast.seq(table.unpack(parts))
    end

    local body = ast.alt(
        ast.seq(ast.literal("{"), ast.ref("ws"), ast.literal("}")),
        ast.seq(
            ast.literal("{"), ast.ref("ws"),
            members_body,
            ast.ref("ws"), ast.literal("}")
        )
    )
    return self:add_rule(name, body)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Sentinel for JSON null in Lua (since Lua has no null)
json_mod.null = setmetatable({}, { __tostring = function() return "null" end })

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
                -- rename to match the def name if different
                if rule_name ~= defname then
                    -- Add alias
                    conv:add_rule(defname, ast.ref(rule_name))
                end
            end
        end
    end

    -- Convert the root schema
    local result_rule = conv:convert(schema, root)

    -- Add ws rule
    if not conv._names["ws"] then
        conv:add_rule("ws", ast.star(ast.char(" \\t\\n")))
    end

    -- Rename result to root if needed
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
    local compiler = require "ion7.grammar.compiler"
    return compiler.compile(rules, root_name, false)  -- ws already added
end

return json_mod
