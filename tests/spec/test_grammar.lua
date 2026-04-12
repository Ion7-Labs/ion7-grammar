--- SPDX-License-Identifier: MIT
--- ion7-grammar — Grammar constructors, Grammar_obj, Composition,
---                trigger_words, from_json_schema_native, tool_pipeline tests.
---
--- Run standalone:  luajit tests/spec/test_grammar.lua
--- Or via runner:   luajit tests/test_pure.lua
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"

-- ─────────────────────────────────────────────────────────────────────────────
-- Grammar constructors
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Grammar constructors")

T.test("from_builder: wraps builder in Grammar_obj", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("x"))
    local g = Grammar.from_builder(b)
    T.ok(type(g.to_gbnf) == "function")
end)

T.test("from_json_schema: boolean", function()
    local gbnf = Grammar.from_json_schema({ type = "boolean" }):to_gbnf()
    T.ok(gbnf:find('"true"'))
    T.ok(gbnf:find('"false"'))
end)

T.test("from_json_schema: integer has [0-9]", function()
    T.ok(Grammar.from_json_schema({ type = "integer" }):to_gbnf():find("%[0%-9%]"))
end)

T.test("from_json_schema: string", function()
    T.ok(type(Grammar.from_json_schema({ type = "string" }):to_gbnf()) == "string")
end)

T.test("from_json_schema: number", function()
    T.ok(type(Grammar.from_json_schema({ type = "number" }):to_gbnf()) == "string")
end)

T.test("from_json_schema: null", function()
    T.ok(Grammar.from_json_schema({ type = "null" }):to_gbnf():find('"null"'))
end)

T.test("from_json_schema: object with required fields", function()
    local g = Grammar.from_json_schema({
        type = "object",
        properties = { name = { type = "string" }, age = { type = "integer" } },
        required = { "name", "age" },
    })
    local gbnf = g:to_gbnf()
    T.ok(gbnf:find('\\"name\\"'))
    T.ok(gbnf:find('\\"age\\"'))
end)

T.test("from_json_schema: array of integers", function()
    local g = Grammar.from_json_schema({ type = "array", items = { type = "integer" } })
    T.ok(type(g:to_gbnf()) == "string")
    T.ok(g:to_gbnf():find("%["))
end)

T.test("from_json_schema: enum values", function()
    local gbnf = Grammar.from_json_schema({ enum = { "ok", "error", "pending" } }):to_gbnf()
    T.ok(gbnf:find('\\"ok\\"') or gbnf:find('"ok"'))
    T.ok(gbnf:find('\\"error\\"') or gbnf:find('"error"'))
end)

T.test("from_json_schema: oneOf", function()
    T.ok(type(Grammar.from_json_schema({
        oneOf = { { type = "string" }, { type = "integer" } }
    }):to_gbnf()) == "string")
end)

T.test("from_json_schema: anyOf", function()
    T.ok(type(Grammar.from_json_schema({
        anyOf = { { type = "boolean" }, { type = "null" } }
    }):to_gbnf()) == "string")
end)

T.test("from_json_schema: allOf shallow merge", function()
    T.no_error(function()
        Grammar.from_json_schema({
            allOf = { { type = "object", properties = { x = { type = "integer" } } } }
        }):to_gbnf()
    end)
end)

T.test("from_json_schema: string with pattern", function()
    T.ok(type(Grammar.from_json_schema({
        type = "string", pattern = "[A-Z]{2,3}"
    }):to_gbnf()) == "string")
end)

T.test("from_json_schema: string with minLength/maxLength", function()
    T.ok(type(Grammar.from_json_schema({
        type = "string", minLength = 1, maxLength = 5
    }):to_gbnf()) == "string")
end)

T.test("from_json_schema: const string", function()
    local gbnf = Grammar.from_json_schema({ const = "hello" }):to_gbnf()
    T.ok(gbnf:find('\\"hello\\"') or gbnf:find('"hello"'))
end)

T.test("from_json_schema: const number", function()
    T.ok(Grammar.from_json_schema({ const = 42 }):to_gbnf():find('"42"'))
end)

T.test("from_json_schema: const boolean true", function()
    T.ok(Grammar.from_json_schema({ const = true }):to_gbnf():find('"true"'))
end)

T.test("from_json_schema: const null sentinel", function()
    T.ok(Grammar.from_json_schema({ const = Grammar.null }):to_gbnf():find('"null"'))
end)

T.test("from_json_schema: multiple types [string, null]", function()
    T.ok(type(Grammar.from_json_schema({ type = { "string", "null" } }):to_gbnf()) == "string")
end)

T.test("from_json_schema: additionalProperties=false", function()
    T.no_error(function()
        Grammar.from_json_schema({
            type = "object",
            properties = { x = { type = "integer" } },
            required = { "x" },
            additionalProperties = false,
        }):to_gbnf()
    end)
end)

T.test("from_json_schema: $ref resolution", function()
    T.no_error(function()
        Grammar.from_json_schema({
            ["$defs"] = { MyStr = { type = "string" } },
            type = "object",
            properties = { name = { ["$ref"] = "#/$defs/MyStr" } },
            required = { "name" },
        }):to_gbnf()
    end)
end)

T.test("from_json_schema: invalid $ref raises error", function()
    T.err(function()
        Grammar.from_json_schema({ ["$ref"] = "external#/foo" }):to_gbnf()
    end, "only local %$ref supported")
end)

T.test("from_json_schema: $ref not found raises error", function()
    T.err(function()
        Grammar.from_json_schema({ ["$ref"] = "#/$defs/Missing" }):to_gbnf()
    end, "%$ref not found")
end)

T.test("from_json_schema: array with minItems/maxItems", function()
    T.no_error(function()
        Grammar.from_json_schema({
            type = "array", items = { type = "integer" }, minItems = 1, maxItems = 3
        }):to_gbnf()
    end)
end)

T.test("from_json_schema: custom root name", function()
    T.ok(Grammar.from_json_schema({ type = "boolean" }, "mybool"):to_gbnf():find("mybool ::="))
end)

T.test("from_json_schema: no type → any json-value", function()
    T.ok(type(Grammar.from_json_schema({}):to_gbnf()) == "string")
end)

T.test("from_type: string primitive", function()
    T.ok(type(Grammar.from_type("string"):to_gbnf()) == "string")
end)

T.test("from_type: integer", function()
    T.ok(Grammar.from_type("integer"):to_gbnf():find("%[0%-9%]"))
end)

T.test("from_type: boolean", function()
    T.ok(Grammar.from_type("boolean"):to_gbnf():find('"true"'))
end)

T.test("from_type: optional string?", function()
    T.ok(type(Grammar.from_type("string?"):to_gbnf()) == "string")
end)

T.test("from_type: array { 'string' }", function()
    T.ok(type(Grammar.from_type({ "string" }):to_gbnf()) == "string")
end)

T.test("from_type: object with fields", function()
    local gbnf = Grammar.from_type({ name = "string", age = "integer" }):to_gbnf()
    T.ok(gbnf:find('\\"name\\"') or gbnf:find('\\"age\\"'))
end)

T.test("from_type: optional field (key with ?)", function()
    T.ok(type(Grammar.from_type({ name = "string", ["score?"] = "number" }):to_gbnf()) == "string")
end)

T.test("from_type: unknown primitive raises error", function()
    T.err(function() Grammar.from_type("unknowntype") end, "unknown primitive type")
end)

T.test("from_regex: \\d+ → [0-9]+", function()
    T.ok(Grammar.from_regex("\\d+"):to_gbnf():find("%[0%-9%]%+"))
end)

T.test("from_regex: custom root name", function()
    T.ok(Grammar.from_regex("\\d+", "digits"):to_gbnf():find("^digits ::="))
end)

T.test("from_enum: produces alternation of values", function()
    local gbnf = Grammar.from_enum("color", { "red", "green", "blue" }):to_gbnf()
    T.ok(gbnf:find('"red"'))
    T.ok(gbnf:find('"green"'))
    T.ok(gbnf:find('"blue"'))
end)

T.test("from_json_enum: values wrapped in JSON quotes", function()
    local gbnf = Grammar.from_json_enum("status", { "ok", "fail" }):to_gbnf()
    T.ok(gbnf:find('\\"ok\\"') or gbnf:find('"ok"'))
end)

T.test("raw: passthrough unchanged", function()
    local src = 'root ::= "hello"\n'
    T.eq(Grammar.raw(src):to_gbnf(), src)
end)

T.test("raw: rules() returns empty table", function()
    T.eq(#Grammar.raw('root ::= "x"'):rules(), 0)
end)

T.test("raw: builder() raises error", function()
    T.err(function() Grammar.raw('root ::= "x"'):builder() end, "raw grammar has no builder")
end)

T.test("raw: merge() raises error", function()
    T.err(function() Grammar.raw('root ::= "x"'):merge({}) end, "raw grammar cannot be merged")
end)

T.test("raw: fuzz() raises error", function()
    T.err(function() Grammar.raw('root ::= "x"'):fuzz() end, "raw grammar cannot be fuzzed")
end)

T.test("raw: inspect() returns the GBNF string", function()
    local src = 'root ::= "x"'
    T.eq(Grammar.raw(src):inspect(), src)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Grammar_obj methods
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Grammar_obj methods")

T.test("to_gbnf: returns string", function()
    T.eq(type(Grammar.from_enum("x", { "a", "b" }):to_gbnf()), "string")
end)

T.test("to_gbnf: override root name", function()
    local g = Grammar.from_enum("color", { "red", "blue" })
    T.ok(g:to_gbnf("color"):match("^color"))
end)

T.test("builder: returns underlying builder", function()
    local g = Grammar.from_enum("x", { "a" })
    T.ok(type(g:builder().rule) == "function")
end)

T.test("rules: returns array of rule names", function()
    local names = Grammar.from_enum("x", { "a", "b" }):rules()
    T.eq(type(names), "table")
    T.ok(#names > 0)
end)

T.test("merge: adds rules from another Grammar_obj, returns self", function()
    local g1 = Grammar.from_enum("color", { "red" })
    local g2 = Grammar.from_enum("size",  { "small" })
    local ret = g1:merge(g2)
    T.eq(ret, g1)
    local names_set = {}
    for _, n in ipairs(g1:rules()) do names_set[n] = true end
    T.ok(names_set["color"])
    T.ok(names_set["size"])
end)

T.test("union: returns new Grammar_obj with both alternatives", function()
    local g1 = Grammar.from_enum("a", { "x" })
    local g2 = Grammar.from_enum("b", { "y" })
    local gu = g1:union(g2)
    T.ok(type(gu.to_gbnf) == "function")
    T.ok(gu:to_gbnf():find('"x"'))
    T.ok(gu:to_gbnf():find('"y"'))
end)

T.test("then_: returns new Grammar_obj that sequences", function()
    local g1 = Grammar.from_regex("[A-Z]{2}")
    local g2 = Grammar.from_regex("[0-9]+")
    T.ok(type(g1:then_(g2):to_gbnf()) == "string")
end)

T.test("then_: with separator", function()
    local g1 = Grammar.from_regex("[a-z]+")
    local g2 = Grammar.from_regex("[a-z]+")
    T.ok(g1:then_(g2, Grammar.literal("-")):to_gbnf():find('"-"'))
end)

T.test("fuzz: returns table of samples and seed", function()
    local g = Grammar.from_enum("color", { "red", "green", "blue" })
    local samples, seed = g:fuzz({ count = 5, seed = 1 })
    T.eq(#samples, 5)
    T.eq(type(seed), "number")
end)

T.test("inspect: returns non-empty string", function()
    local s = Grammar.from_enum("x", { "a", "b" }):inspect()
    T.eq(type(s), "string")
    T.ok(#s > 0)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Composition
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Composition")

T.test("union: root has alternation", function()
    local g = Grammar.union(Grammar.from_regex("[a-z]+"), Grammar.from_regex("[0-9]+"))
    local gbnf = g:to_gbnf()
    T.ok(gbnf:find("root ::="))
    T.ok(gbnf:find("|"))
end)

T.test("sequence: produces root with both grammars in order", function()
    local g = Grammar.sequence(Grammar.from_regex("[A-Z]"), Grammar.from_regex("[0-9]"))
    T.ok(type(g:to_gbnf()) == "string")
end)

T.test("sequence: with separator inserts separator node", function()
    local g = Grammar.sequence(
        Grammar.from_regex("[a-z]+"),
        Grammar.from_regex("[0-9]+"),
        { separator = Grammar.literal("-") }
    )
    T.ok(g:to_gbnf():find('"-"'))
end)

T.test("wrap: surrounds grammar with prefix/suffix", function()
    local gbnf = Grammar.wrap(Grammar.from_regex("[a-z]+"), "[", "]"):to_gbnf()
    T.ok(gbnf:find('"%["') or gbnf:find('"["'))
    T.ok(gbnf:find('"%]"') or gbnf:find('"]"'))
end)

T.test("wrap: ws=false omits whitespace rule", function()
    local g = Grammar.wrap(Grammar.from_regex("[a-z]+"), "(", ")", false)
    T.ok(type(g:to_gbnf()) == "string")
end)

T.test("interleave: comma-separated grammar", function()
    local g = Grammar.interleave(Grammar.from_regex("[a-z]+"), ",", 1, 3)
    T.ok(type(g:to_gbnf()) == "string")
end)

T.test("repeat_g: min/max bounds", function()
    local g = Grammar.repeat_g(Grammar.from_regex("[0-9]"), 2, 4)
    T.ok(type(g:to_gbnf()) == "string")
end)

T.test("repeat_g: with separator", function()
    local g = Grammar.repeat_g(Grammar.from_regex("[a-z]+"), 1, 3, Grammar.literal(","))
    T.ok(type(g:to_gbnf()) == "string")
end)

T.test("optional: wraps grammar as ?", function()
    T.ok(Grammar.optional(Grammar.from_regex("[a-z]+")):to_gbnf():find("%?"))
end)

T.test("annotate: renames root rule", function()
    T.ok(Grammar.annotate(Grammar.from_enum("x", { "a", "b" }), "myname"):to_gbnf():find("myname ::="))
end)

T.test("compose: prefix rewriting prevents broken refs", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.seq(Grammar.ref("sub"), Grammar.literal("!")))
    b:rule("sub",  Grammar.char("a-z"))
    local g1 = Grammar.from_builder(b)
    local g2 = Grammar.from_regex("[0-9]+")
    T.no_error(function() Grammar.union(g1, g2):to_gbnf() end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Grammar_obj:trigger_words()
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Grammar_obj:trigger_words()")

T.test("trigger_words: literal root returns that literal", function()
    local g = Grammar.from_builder(
        Grammar.builder():rule("root", Grammar.literal("SELECT"))
    )
    local tw = g:trigger_words()
    T.eq(#tw, 1)
    T.eq(tw[1], "SELECT")
end)

T.test("trigger_words: seq returns first child only", function()
    local g = Grammar.from_builder(
        Grammar.builder():rule("root",
            Grammar.seq(Grammar.literal("{"), Grammar.literal("}")))
    )
    local tw = g:trigger_words()
    T.eq(#tw, 1)
    T.eq(tw[1], "{")
end)

T.test("trigger_words: alt returns all alternatives", function()
    local g = Grammar.from_builder(
        Grammar.builder():rule("root",
            Grammar.alt(Grammar.literal("true"), Grammar.literal("false")))
    )
    local tw = g:trigger_words()
    table.sort(tw)
    T.eq(#tw, 2)
    T.eq(tw[1], "false")
    T.eq(tw[2], "true")
end)

T.test("trigger_words: rep with min=0 skipped (optional), min=1 included", function()
    local g_opt = Grammar.from_builder(
        Grammar.builder():rule("root",
            Grammar.rep(Grammar.literal("x"), 0, 5))
    )
    T.eq(#g_opt:trigger_words(), 0, "min=0 means optional → no trigger")

    local g_req = Grammar.from_builder(
        Grammar.builder():rule("root",
            Grammar.rep(Grammar.literal("y"), 1, 5))
    )
    local tw = g_req:trigger_words()
    T.eq(#tw, 1)
    T.eq(tw[1], "y")
end)

T.test("trigger_words: ref resolves to target rule", function()
    local g = Grammar.from_builder(
        Grammar.builder()
            :rule("root", Grammar.ref("inner"))
            :rule("inner", Grammar.literal("BEGIN"))
    )
    local tw = g:trigger_words()
    T.eq(#tw, 1)
    T.eq(tw[1], "BEGIN")
end)

T.test("trigger_words: max_prefix truncates long literals", function()
    local g = Grammar.from_builder(
        Grammar.builder():rule("root", Grammar.literal("SELECT_ALL"))
    )
    local tw = g:trigger_words({ max_prefix = 6 })
    T.eq(#tw, 1)
    T.eq(tw[1], "SELECT")
end)

T.test("trigger_words: char nodes are skipped (too broad)", function()
    local g = Grammar.from_builder(
        Grammar.builder():rule("root", Grammar.char("0-9"))
    )
    T.eq(#g:trigger_words(), 0)
end)

T.test("trigger_words: JSON schema grammar starts with {", function()
    local g = Grammar.from_json_schema({
        type = "object",
        properties = { status = { type = "string" } },
    })
    local tw = g:trigger_words()
    local found = false
    for _, s in ipairs(tw) do
        if s == "{" then found = true; break end
    end
    T.ok(found, "JSON object grammar should trigger on '{'")
end)

T.test("trigger_words: result is sorted", function()
    local g = Grammar.from_builder(
        Grammar.builder():rule("root",
            Grammar.alt(Grammar.literal("z"), Grammar.literal("a"),
                        Grammar.literal("m")))
    )
    local tw = g:trigger_words()
    T.eq(tw[1], "a")
    T.eq(tw[2], "m")
    T.eq(tw[3], "z")
end)

T.test("trigger_words: raw grammar returns empty (no builder)", function()
    local g = Grammar.raw('root ::= "x"')
    T.eq(type(g:trigger_words()), "table")
    T.eq(#g:trigger_words(), 0)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Grammar.from_json_schema_native()
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Grammar.from_json_schema_native()")

T.test("from_json_schema_native: function is exported", function()
    T.eq(type(Grammar.from_json_schema_native), "function")
end)

T.test("from_json_schema_native: errors on non-string/non-table input", function()
    T.err(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        Grammar.from_json_schema_native(42)
    end, "schema must be a string or table")
end)

T.test("from_json_schema_native: errors on boolean input", function()
    T.err(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        Grammar.from_json_schema_native(true)
    end, "schema must be a string or table")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Grammar.tool_pipeline()
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Grammar.tool_pipeline()")

local sample_tools = {
    { name = "get_weather", schema = { type = "object",
        properties = { city = { type = "string" } } } },
}

T.test("tool_pipeline: returns two values (grammar, parse_fn)", function()
    local g, parse = Grammar.tool_pipeline(sample_tools)
    T.eq(type(g),     "table",    "first return is Grammar_obj")
    T.eq(type(parse), "function", "second return is parse function")
end)

T.test("tool_pipeline: grammar has to_gbnf", function()
    local g = Grammar.tool_pipeline(sample_tools)
    T.eq(type(g.to_gbnf), "function")
end)

T.test("tool_pipeline: grammar GBNF contains tool name", function()
    local g = Grammar.tool_pipeline(sample_tools)
    T.ok(g:to_gbnf():find("get_weather"), "GBNF should reference the tool name")
end)

T.test("tool_pipeline: parse returns nil+error when ion7.vendor.json absent", function()
    local _, parse = Grammar.tool_pipeline(sample_tools)
    local calls, err = parse('{"name":"get_weather","arguments":{"city":"Paris"}}')
    if calls == nil then
        T.ok(type(err) == "string", "error must be a string")
    else
        T.eq(type(calls), "table")
    end
end)

T.test("tool_pipeline: errors on empty tools", function()
    T.err(function() Grammar.tool_pipeline({}) end, "non%-empty")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Standalone runner
-- ─────────────────────────────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:find("test_grammar") then
    local ok = T.summary()
    os.exit(ok and 0 or 1)
end
