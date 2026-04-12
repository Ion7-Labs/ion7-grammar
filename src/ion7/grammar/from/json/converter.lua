--- SPDX-License-Identifier: MIT
--- JSON Schema → GBNF internal converter.
---
--- The Converter class walks a JSON Schema (Lua table) and emits GBNF rules
--- into an internal rule list. Used exclusively by from/json/init.lua.
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast     = require "ion7.grammar.ast"
local regex_m = require "ion7.grammar.from.regex"

--- @class Converter
local Converter = {}
Converter.__index = Converter

function Converter.new(schema)
    return setmetatable({
        _root    = schema,
        _rules   = {},
        _names   = {},
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

function Converter:resolve_ref(ref)
    local path = ref:match("^#/(.+)$")
    if not path then
        error("[ion7.grammar.from.json] only local $ref supported: " .. ref)
    end
    local parts = {}
    for p in path:gmatch("[^/]+") do parts[#parts+1] = p end
    local node = self._root
    for _, p in ipairs(parts) do
        node = node[p]
        if not node then
            error("[ion7.grammar.from.json] $ref not found: " .. ref)
        end
    end
    return node
end

function Converter:convert(schema, hint)
    if type(schema) == "boolean" then
        if schema then return self:add_rule("any-value", ast.ref("json-value"))
        else error("[ion7.grammar.from.json] false schema not supported") end
    end

    if schema["$ref"] then
        return self:convert(self:resolve_ref(schema["$ref"]), hint)
    end

    if schema["const"] ~= nil then
        local name = self:fresh(hint or "const")
        return self:add_rule(name, self:encode_value(schema["const"]))
    end

    if schema["enum"] then
        local alts = {}
        for _, v in ipairs(schema["enum"]) do
            alts[#alts+1] = self:encode_value(v)
        end
        local name = self:fresh(hint or "enum")
        return self:add_rule(name, ast.alt(table.unpack(alts)))
    end

    local combo = schema["oneOf"] or schema["anyOf"]
    if combo then
        local alts = {}
        for _, s in ipairs(combo) do
            alts[#alts+1] = ast.ref(self:convert(s))
        end
        local name = self:fresh(hint or "oneof")
        return self:add_rule(name, ast.alt(table.unpack(alts)))
    end

    if schema["allOf"] then
        local merged = {}
        for _, s in ipairs(schema["allOf"]) do
            for k, v in pairs(s) do merged[k] = v end
        end
        return self:convert(merged, hint)
    end

    local t = schema["type"]

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

    return self:ensure_base("json-value")
end

function Converter:encode_value(v)
    local null_sentinel = require("ion7.grammar.from.json").null
    if v == nil or v == null_sentinel then
        return ast.literal("null")
    elseif type(v) == "boolean" then
        return ast.literal(v and "true" or "false")
    elseif type(v) == "number" then
        return ast.literal(tostring(v))
    elseif type(v) == "string" then
        local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"')
                         :gsub('\n', '\\n'):gsub('\r', '\\r')
                         :gsub('\t', '\\t')
        return ast.literal('"' .. escaped .. '"')
    elseif type(v) == "table" then
        error("[ion7.grammar.from.json] table const not supported (use $ref)")
    end
    error("[ion7.grammar.from.json] unsupported const type: " .. type(v))
end

function Converter:ensure_base(name)
    if self._names[name] then return name end
    self._names[name] = true
    local body
    if name == "null" then
        body = ast.literal("null")
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
            ast.opt(ast.seq(ast.literal("."), ast.plus(ast.char("0-9")))),
            ast.opt(ast.seq(
                ast.char("eE"),
                ast.opt(ast.char("+-")),
                ast.plus(ast.char("0-9"))
            ))
        )
    elseif name == "string" then
        body = ast.seq(
            ast.literal('"'),
            ast.star(ast.alt(
                ast.char('^"\\\\'),
                ast.seq(ast.literal("\\\\"), ast.char('.'))
            )),
            ast.literal('"')
        )
    elseif name == "json-value" then
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
        error("[ion7.grammar.from.json] unknown base: " .. name)
    end
    self._rules[#self._rules + 1] = { name = name, body = body }
    return name
end

function Converter:convert_string(schema, hint)
    if schema["pattern"] then
        local name = self:fresh(hint or "str")
        local pat_node = regex_m.to_ast(schema["pattern"])
        local body = ast.seq(ast.literal('"'), pat_node, ast.literal('"'))
        return self:add_rule(name, body)
    end

    local min_len = schema["minLength"]
    local max_len = schema["maxLength"]
    if min_len or max_len then
        local name = self:fresh(hint or "str")
        local char_node = ast.alt(
            ast.char('^"\\\\'),
            ast.seq(ast.literal("\\\\"), ast.char('.'))
        )
        local body = ast.seq(
            ast.literal('"'),
            ast.rep(char_node, min_len or 0, max_len or -1),
            ast.literal('"')
        )
        return self:add_rule(name, body)
    end

    return self:ensure_base("string")
end

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

    local items_body
    if min_i == 0 and max_i == -1 then
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

function Converter:convert_object(schema, hint)
    local name = self:fresh(hint or "obj")

    local props    = schema["properties"] or {}
    local required = {}
    for _, k in ipairs(schema["required"] or {}) do required[k] = true end

    -- Sort for deterministic GBNF (stable KV prefix cache).
    local req_keys = {}
    local opt_keys = {}
    for k in pairs(props) do
        if required[k] then req_keys[#req_keys + 1] = k
        else opt_keys[#opt_keys + 1] = k end
    end
    table.sort(req_keys)
    table.sort(opt_keys)

    local req_fields = {}
    local opt_fields = {}

    local function process_key(k)
        local v = props[k]
        local field_rule = self:convert(v, name .. "-" .. k:gsub("_", "-"))
        local field_body = ast.seq(
            ast.literal('"' .. k .. '"'),
            ast.ref("ws"),
            ast.literal(":"),
            ast.ref("ws"),
            ast.ref(field_rule)
        )
        return self:add_rule(name .. "-kv-" .. k:gsub("_", "-"), field_body)
    end

    for _, k in ipairs(req_keys) do req_fields[#req_fields + 1] = process_key(k) end
    for _, k in ipairs(opt_keys) do opt_fields[#opt_fields + 1] = process_key(k) end

    local allow_extra = schema["additionalProperties"]
    if allow_extra == nil then allow_extra = true end

    local parts = {}
    for i, f in ipairs(req_fields) do
        if i == 1 then
            parts[#parts + 1] = ast.ref(f)
        else
            parts[#parts + 1] = ast.seq(ast.literal(","), ast.ref("ws"), ast.ref(f))
        end
    end
    for _, f in ipairs(opt_fields) do
        local comma_field = ast.seq(ast.literal(","), ast.ref("ws"), ast.ref(f))
        if #parts == 0 then
            parts[#parts + 1] = ast.opt(ast.ref(f))
        else
            parts[#parts + 1] = ast.opt(comma_field)
        end
    end
    if allow_extra and allow_extra ~= false then
        self:ensure_base("string")
        self:ensure_base("json-value")
        parts[#parts + 1] = ast.star(ast.seq(
            ast.literal(","), ast.ref("ws"),
            ast.ref("string"), ast.ref("ws"),
            ast.literal(":"), ast.ref("ws"),
            ast.ref("json-value")
        ))
    end

    local members_body
    if #parts == 0 then     members_body = ast.literal("")
    elseif #parts == 1 then members_body = parts[1]
    else                    members_body = ast.seq(table.unpack(parts)) end

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

return Converter
