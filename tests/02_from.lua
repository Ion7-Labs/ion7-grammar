--- SPDX-License-Identifier: MIT
--- ion7-grammar — from.* module tests (regex, JSON Schema, types, dynamic).
---
--- Run standalone:  luajit tests/spec/test_from.lua
--- Or via runner:   luajit tests/test_pure.lua
require "tests.helpers"

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"
local regex_m = require "ion7.grammar.from.regex"
local json_m  = require "ion7.grammar.from.json"
local Types   = require "ion7.grammar.from.types"
local Dynamic = require "ion7.grammar.from.dynamic"

-- Regex

T.suite("Regex")

T.test("\\d+ → [0-9]+", function()
    T.ok(Grammar.from_regex("\\d+"):to_gbnf():find("%[0%-9%]%+"))
end)

T.test("\\D → [^0-9]", function()
    T.ok(Grammar.from_regex("\\D"):to_gbnf():find("%[%^0%-9%]"))
end)

T.test("\\w+ → word class", function()
    local gbnf = Grammar.from_regex("\\w+"):to_gbnf()
    T.ok(gbnf:find("a%-zA%-Z0%-9"))
end)

T.test("\\W → negated word class", function()
    T.ok(Grammar.from_regex("\\W"):to_gbnf():find("%^"))
end)

T.test("\\s+ → whitespace class", function()
    T.ok(type(Grammar.from_regex("\\s+"):to_gbnf()) == "string")
end)

T.test("\\S+ → negated whitespace", function()
    T.ok(Grammar.from_regex("\\S+"):to_gbnf():find("%^"))
end)

T.test("[a-z]* → [a-z]*", function()
    T.ok(Grammar.from_regex("[a-z]*"):to_gbnf():find("%[a%-z%]%*"))
end)

T.test("(a|b)+ → alternation in group with +", function()
    local gbnf = Grammar.from_regex("(a|b)+"):to_gbnf()
    T.ok(gbnf:find('"a" | "b"'))
    T.ok(gbnf:find("%+"))
end)

T.test("{n,m} bounded repetition", function()
    T.ok(Grammar.from_regex("[0-9]{2,4}"):to_gbnf():find("{2,4}"))
end)

T.test("{n} exact repetition", function()
    T.ok(Grammar.from_regex("[A-Z]{3}"):to_gbnf():find("{3}"))
end)

T.test("{n,} at-least repetition", function()
    T.ok(Grammar.from_regex("[a-z]{2,}"):to_gbnf():find("{2,}"))
end)

T.test(". → [^\\n] (any except newline)", function()
    T.ok(Grammar.from_regex(".+"):to_gbnf():find("%^"))
end)

T.test("\\n escape → literal newline in AST", function()
    local n = regex_m.to_ast("\\n")
    T.eq(n.kind, "literal")
    T.eq(n.value, "\n")
end)

T.test("\\t escape → literal tab in AST", function()
    local n = regex_m.to_ast("\\t")
    T.eq(n.kind, "literal")
    T.eq(n.value, "\t")
end)

T.test("anchors ^ and $ are no-ops", function()
    T.no_error(function() Grammar.from_regex("^[a-z]+$"):to_gbnf() end)
end)

T.test("alternation a|b|c", function()
    local gbnf = Grammar.from_regex("cat|dog|bird"):to_gbnf()
    T.ok(gbnf:find('"cat"'))
    T.ok(gbnf:find('"dog"'))
    T.ok(gbnf:find('"bird"'))
end)

T.test("implicit sequence 'abc' merged to one literal", function()
    T.ok(Grammar.from_regex("abc"):to_gbnf():find('"abc"'))
end)

T.test("optional atom with ?", function()
    T.ok(Grammar.from_regex("[a-z]?"):to_gbnf():find("%?"))
end)

T.test("email-like pattern compiles", function()
    T.no_error(function()
        Grammar.from_regex("[a-z]+@[a-z]+\\.[a-z]{2,4}"):to_gbnf()
    end)
end)

T.test("date pattern \\d{4}-\\d{2}-\\d{2} compiles", function()
    T.no_error(function()
        Grammar.from_regex("\\d{4}-\\d{2}-\\d{2}"):to_gbnf()
    end)
end)

T.test("negated char class [^abc]", function()
    T.ok(Grammar.from_regex("[^abc]"):to_gbnf():find("%^"))
end)

T.test("regex_m.to_gbnf: returns GBNF string with named root", function()
    local gbnf = regex_m.to_gbnf("\\d+", "digits")
    T.eq(type(gbnf), "string")
    T.ok(gbnf:find("digits ::="))
end)

-- JSON Schema

T.suite("JSON Schema")

T.test("json_m.null: tostring is 'null'", function()
    T.eq(tostring(Grammar.null), "null")
end)

T.test("json_m.to_gbnf: returns GBNF string", function()
    local gbnf = json_m.to_gbnf({ type = "boolean" })
    T.eq(type(gbnf), "string")
    T.ok(gbnf:find('"true"'))
end)

T.test("json_m.to_rules: returns rules array and root name", function()
    local rules, root = json_m.to_rules({ type = "boolean" })
    T.eq(type(rules), "table")
    T.ok(#rules > 0)
    T.eq(type(root), "string")
end)

T.test("to_gbnf: enum integers produce literals", function()
    local gbnf = Grammar.from_json_schema({ enum = { 1, 2, 3 } }):to_gbnf()
    T.ok(gbnf:find('"1"'))
    T.ok(gbnf:find('"2"'))
end)

T.test("to_gbnf: nested object compiles", function()
    T.no_error(function()
        Grammar.from_json_schema({
            type = "object",
            properties = {
                user = {
                    type = "object",
                    properties = { id = { type = "integer" } },
                    required = { "id" },
                },
            },
            required = { "user" },
        }):to_gbnf()
    end)
end)

T.test("to_gbnf: array typed items compiles", function()
    local gbnf = Grammar.from_json_schema({ type = "array", items = { type = "boolean" } }):to_gbnf()
    T.ok(gbnf:find('"true"') or gbnf:find("boolean"))
end)

-- Type annotations

T.suite("Type annotations")

T.test("to_schema: string → {type=string}", function()
    T.eq(Types.to_schema("string").type, "string")
end)

T.test("to_schema: number → {type=number}", function()
    T.eq(Types.to_schema("number").type, "number")
end)

T.test("to_schema: integer → {type=integer}", function()
    T.eq(Types.to_schema("integer").type, "integer")
end)

T.test("to_schema: boolean → {type=boolean}", function()
    T.eq(Types.to_schema("boolean").type, "boolean")
end)

T.test("to_schema: null → {type=null}", function()
    T.eq(Types.to_schema("null").type, "null")
end)

T.test("to_schema: any → {}", function()
    T.eq(Types.to_schema("any").type, nil)
end)

T.test("to_schema: optional string? → oneOf with 2 entries", function()
    local s = Types.to_schema("string?")
    T.ok(s.oneOf ~= nil)
    T.eq(#s.oneOf, 2)
end)

T.test("to_schema: array {'string'} → array schema", function()
    local s = Types.to_schema({ "string" })
    T.eq(s.type, "array")
    T.eq(s.items.type, "string")
end)

T.test("to_schema: object → object schema with properties", function()
    local s = Types.to_schema({ name = "string", age = "integer" })
    T.eq(s.type, "object")
    T.ok(s.properties ~= nil)
    T.ok(s.properties.name ~= nil)
    T.ok(s.properties.age ~= nil)
end)

T.test("to_schema: required fields sorted deterministically", function()
    local s = Types.to_schema({ b = "string", a = "integer" })
    T.eq(s.required[1], "a")
    T.eq(s.required[2], "b")
end)

T.test("to_schema: optional field (key?) not in required", function()
    local s = Types.to_schema({ name = "string", ["score?"] = "number" })
    local in_req = false
    for _, k in ipairs(s.required or {}) do
        if k == "score" then in_req = true end
    end
    T.ok(not in_req)
end)

T.test("to_schema: unknown type raises error", function()
    T.err(function() Types.to_schema("imaginary") end, "unknown primitive type")
end)

T.test("to_schema: unsupported type raises error", function()
    T.err(function() Types.to_schema(42) end, "unsupported type annotation")
end)

T.test("from_type: delegates to from_json_schema, returns Grammar_obj", function()
    local g = Grammar.from_type({ status = "string", code = "integer" })
    T.ok(type(g.to_gbnf) == "function")
end)

T.test("from_function: ignores name, uses params", function()
    -- Types.from_function returns a Builder; Grammar.from_type wraps it in Grammar_obj.
    local b = Types.from_function("my_func", { query = "string", limit = "integer" })
    T.ok(type(b:compile()) == "string")
end)

-- Dynamic grammars

T.suite("Dynamic grammars")

T.test("from_enum: basic alternation", function()
    local b = Dynamic.from_enum("status", { "ok", "error" })
    local gbnf = b:compile()
    T.ok(gbnf:find('"ok"'))
    T.ok(gbnf:find('"error"'))
end)

T.test("from_enum: longest-first ordering", function()
    local b = Dynamic.from_enum("op", { "GET", "GETTER", "POST" })
    local gbnf = b:compile()
    local pos_getter = gbnf:find('"GETTER"')
    local pos_get    = gbnf:find('"GET"')
    T.ok(pos_getter ~= nil and pos_get ~= nil)
    T.ok(pos_getter < pos_get, "GETTER before GET (longest-first)")
end)

T.test("from_enum: deduplication", function()
    local b = Dynamic.from_enum("x", { "a", "b", "a", "c" })
    local _, count_a = b:compile():gsub('"a"', '')
    T.eq(count_a, 1)
end)

T.test("from_enum: asserts rule_name is string", function()
    T.err(function() Dynamic.from_enum(42, { "x" }) end, "rule_name must be a string")
end)

T.test("from_enum: asserts values non-empty", function()
    T.err(function() Dynamic.from_enum("x", {}) end, "non%-empty")
end)

T.test("from_json_enum: wraps values in JSON quotes", function()
    local gbnf = Dynamic.from_json_enum("status", { "ok", "fail" }):compile()
    T.ok(gbnf:find('\\"ok\\"') or gbnf:find('"ok"'))
end)

T.test("from_json_enum: asserts non-empty values", function()
    T.err(function() Dynamic.from_json_enum("x", {}) end, "non%-empty")
end)

T.test("from_json_enum: deduplication", function()
    T.no_error(function() Dynamic.from_json_enum("x", { "a", "a", "b" }):compile() end)
end)

T.test("from_schema: builds multiple rules", function()
    local b = Dynamic.from_schema({
        color = { "red", "green" },
        size  = { "small", "large" },
    })
    T.ok(b._names["color"])
    T.ok(b._names["size"])
end)

T.test("from_values_with_pattern: behaves like from_enum", function()
    local b = Dynamic.from_values_with_pattern("method", { "GET", "POST" }, "[A-Z]+")
    T.ok(b._names["method"])
end)

T.test("from_tools: single tool produces tool-call rule", function()
    local gbnf = Grammar.from_tools({
        { name = "search", schema = {
            type = "object",
            properties = { q = { type = "string" } },
            required = { "q" },
        }}
    }):to_gbnf()
    T.ok(gbnf:find("tool%-search") or gbnf:find("tool%-call"), "tool rule present")
    T.ok(gbnf:find([[\"name\"]]) or gbnf:find('"name"'), '"name" key present')
end)

T.test("from_tools: multiple tools produce alternation", function()
    local gbnf = Grammar.from_tools({
        { name = "search", schema = { type = "object" } },
        { name = "read",   schema = { type = "object" } },
    }):to_gbnf()
    T.ok(gbnf:find("|"))
end)

T.test("from_tools: asserts non-empty tools", function()
    T.err(function() Grammar.from_tools({}) end, "non%-empty")
end)

T.test("Grammar.from_enum: returns Grammar_obj", function()
    T.ok(type(Grammar.from_enum("c", { "x", "y" }).to_gbnf) == "function")
end)

T.test("Grammar.from_json_enum: returns Grammar_obj", function()
    T.ok(type(Grammar.from_json_enum("s", { "a", "b" }).to_gbnf) == "function")
end)

local ok = T.summary()
os.exit(ok and 0 or 1)
