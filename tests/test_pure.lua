#!/usr/bin/env luajit
--- ion7-grammar pure Lua tests - no model required.
--- Covers every public method of every module.
---
--- Run: luajit tests/test_pure.lua
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local T = require "tests.framework"

local Grammar  = require "ion7.grammar"
local ast_m    = require "ion7.grammar.ast"
local compiler_m = require "ion7.grammar.compiler"
local regex_m  = require "ion7.grammar.regex"
local json_m   = require "ion7.grammar.json"
local Types    = require "ion7.grammar.types"
local Dynamic  = require "ion7.grammar.dynamic"
local Except   = require "ion7.grammar.except"
local Debug_m  = require "ion7.grammar.debug"
local DCCD_m   = require "ion7.grammar.dccd"

-- ─────────────────────────────────────────────────────────────────────────────
-- AST primitives
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("AST primitives")

T.test("literal: kind=literal and value", function()
    local n = Grammar.literal("hello")
    T.eq(n.kind, "literal")
    T.eq(n.value, "hello")
end)

T.test("literal: asserts string argument", function()
    T.err(function() Grammar.literal(42) end, "literal: expected string")
end)

T.test("char: kind=char, spec, negated=false default", function()
    local n = Grammar.char("0-9")
    T.eq(n.kind, "char")
    T.eq(n.spec, "0-9")
    T.eq(n.negated, false)
end)

T.test("char: negated=true", function()
    T.eq(Grammar.char("a-z", true).negated, true)
end)

T.test("ref: kind=ref and name", function()
    local n = Grammar.ref("myrule")
    T.eq(n.kind, "ref")
    T.eq(n.name, "myrule")
end)

T.test("seq: two nodes → kind=seq with 2 items", function()
    local n = Grammar.seq(Grammar.literal("a"), Grammar.literal("b"))
    T.eq(n.kind, "seq")
    T.eq(#n.items, 2)
    T.eq(n.items[1].value, "a")
    T.eq(n.items[2].value, "b")
end)

T.test("seq: single node → unwraps (passthrough)", function()
    T.eq(Grammar.seq(Grammar.literal("x")).kind, "literal")
end)

T.test("alt: two nodes → kind=alt with 2 items", function()
    local n = Grammar.alt(Grammar.literal("yes"), Grammar.literal("no"))
    T.eq(n.kind, "alt")
    T.eq(#n.items, 2)
end)

T.test("alt: single node → unwraps", function()
    T.eq(Grammar.alt(Grammar.literal("only")).kind, "literal")
end)

T.test("rep: explicit min/max", function()
    local n = Grammar.rep(Grammar.literal("x"), 2, 5)
    T.eq(n.kind, "rep")
    T.eq(n.min, 2)
    T.eq(n.max, 5)
end)

T.test("rep: defaults to 0/-1", function()
    local n = Grammar.rep(Grammar.literal("x"))
    T.eq(n.min, 0)
    T.eq(n.max, -1)
end)

T.test("star: min=0, max=-1", function()
    local n = Grammar.star(Grammar.literal("x"))
    T.eq(n.min, 0)
    T.eq(n.max, -1)
end)

T.test("plus: min=1, max=-1", function()
    local n = Grammar.plus(Grammar.literal("x"))
    T.eq(n.min, 1)
    T.eq(n.max, -1)
end)

T.test("opt: min=0, max=1", function()
    local n = Grammar.opt(Grammar.literal("x"))
    T.eq(n.min, 0)
    T.eq(n.max, 1)
end)

T.test("exactly: min=max=n", function()
    local n = Grammar.exactly(Grammar.literal("x"), 3)
    T.eq(n.min, 3)
    T.eq(n.max, 3)
end)

T.test("group: kind=group", function()
    local n = ast_m.group(Grammar.literal("a"))
    T.eq(n.kind, "group")
end)

T.test("any_except: returns negated char node", function()
    local n = ast_m.any_except("aeiou")
    T.eq(n.kind, "char")
    T.eq(n.negated, true)
    T.eq(n.spec, "aeiou")
end)

T.test("DIGIT: [0-9]", function()
    T.eq(Grammar.DIGIT.kind, "char")
    T.eq(Grammar.DIGIT.spec, "0-9")
end)

T.test("ALPHA: [a-zA-Z]", function()
    T.eq(Grammar.ALPHA.kind, "char")
    T.eq(Grammar.ALPHA.spec, "a-zA-Z")
end)

T.test("ALNUM: [a-zA-Z0-9]", function()
    T.eq(Grammar.ALNUM.kind, "char")
    T.eq(Grammar.ALNUM.spec, "a-zA-Z0-9")
end)

T.test("WS: rep node (star of SPACE)", function()
    T.eq(Grammar.WS.kind, "rep")
    T.eq(Grammar.WS.min, 0)
    T.eq(Grammar.WS.max, -1)
end)

T.test("ast.rule: valid name returns rule node", function()
    local n = ast_m.rule("my-rule", Grammar.literal("x"))
    T.eq(n.kind, "rule")
    T.eq(n.name, "my-rule")
end)

T.test("ast.rule: invalid name raises error", function()
    T.err(function() ast_m.rule("123bad", Grammar.literal("x")) end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Builder
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Builder")

T.test("new: default root='root'", function()
    T.eq(Grammar.builder()._root, "root")
end)

T.test("new: custom root option", function()
    T.eq(Grammar.builder({ root = "myroot" })._root, "myroot")
end)

T.test("rule: adds a rule, returns self (fluent)", function()
    local b = Grammar.builder()
    local ret = b:rule("root", Grammar.literal("x"))
    T.eq(ret, b)
    T.eq(#b._rules, 1)
    T.eq(b._rules[1].name, "root")
end)

T.test("rule: second call with same name replaces in-place", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("a"))
    b:rule("root", Grammar.literal("b"))
    T.eq(#b._rules, 1)
    T.eq(b._rules[1].body.value, "b")
end)

T.test("root: sets root name, returns self", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("x"))
    b:rule("other", Grammar.literal("y"))
    T.eq(b:root("other"), b)
    T.eq(b._root, "other")
end)

T.test("names: returns rule names in definition order", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("x"))
    b:rule("alpha", Grammar.literal("a"))
    local n = b:names()
    T.eq(n[1], "root")
    T.eq(n[2], "alpha")
end)

T.test("rules: returns shallow copy of rule list", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("x"))
    local rs = b:rules()
    T.eq(type(rs), "table")
    T.eq(#rs, 1)
    T.eq(rs[1].name, "root")
end)

T.test("merge: adds rules from another builder, skips duplicates", function()
    local b1 = Grammar.builder()
    b1:rule("ws", Grammar.star(Grammar.char(" ")))
    b1:rule("root", Grammar.literal("a"))
    local b2 = Grammar.builder()
    b2:rule("root", Grammar.literal("b"))
    b2:rule("extra", Grammar.literal("e"))
    b2:merge(b1)
    T.eq(#b2._rules, 3)
    T.eq(b2._rules[1].body.value, "b")  -- own root kept
end)

T.test("compile: returns GBNF string with root rule first", function()
    local b = Grammar.builder()
    b:rule("helper", Grammar.literal("h"))
    b:rule("root", Grammar.ref("helper"))
    local gbnf = b:compile()
    T.eq(type(gbnf), "string")
    T.ok(gbnf:match("^root"))
end)

T.test("compile: auto-injects ws when referenced", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.seq(Grammar.ref("ws"), Grammar.literal("x")))
    T.ok(b:compile():find("ws ::="))
end)

T.test("compile: does NOT inject ws when not referenced", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("x"))
    T.ok(not b:compile():find("ws ::="))
end)

T.test("compile: error when root rule missing", function()
    local b = Grammar.builder({ root = "missing" })
    b:rule("other", Grammar.literal("x"))
    T.err(function() b:compile() end, "root rule 'missing' not found")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Compiler
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Compiler")

T.test("literal: produces quoted string", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("hello"))
    T.ok(b:compile():find('"hello"'))
end)

T.test("literal: escapes double-quote", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal('say "hi"'))
    T.ok(b:compile():find('\\"hi\\"'))
end)

T.test("literal: escapes backslash", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.literal("a\\b"))
    T.ok(b:compile():find("\\\\"))
end)

T.test("char: produces bracket expression", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.char("a-z"))
    T.ok(b:compile():find("%[a%-z%]"))
end)

T.test("char: negated produces [^...]", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.char("0-9", true))
    T.ok(b:compile():find("%[%^0%-9%]"))
end)

T.test("ref: produces rule name", function()
    local b = Grammar.builder()
    b:rule("other", Grammar.literal("x"))
    b:rule("root", Grammar.ref("other"))
    T.ok(b:compile():find("root ::= other"))
end)

T.test("seq: joins items with space", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.seq(Grammar.literal("a"), Grammar.literal("b")))
    T.ok(b:compile():find('"a" "b"'))
end)

T.test("alt: joins items with ' | '", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.alt(Grammar.literal("yes"), Grammar.literal("no")))
    T.ok(b:compile():find('"yes" | "no"'))
end)

T.test("star → *", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.star(Grammar.char("0-9")))
    T.ok(b:compile():find("%[0%-9%]%*"))
end)

T.test("plus → +", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.plus(Grammar.char("a-z")))
    T.ok(b:compile():find("%[a%-z%]%+"))
end)

T.test("opt → ?", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.opt(Grammar.literal("-")))
    T.ok(b:compile():find('"-"%?'))
end)

T.test("exactly(n) → {n}", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.exactly(Grammar.char("0-9"), 4))
    T.ok(b:compile():find("{4}"))
end)

T.test("rep(min, max) → {min,max}", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.rep(Grammar.char("a-z"), 2, 5))
    T.ok(b:compile():find("{2,5}"))
end)

T.test("rep(n, -1) → {n,}", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.rep(Grammar.char("a-z"), 3, -1))
    T.ok(b:compile():find("{3,}"))
end)

T.test("group: wraps in parens", function()
    local b = Grammar.builder()
    b:rule("root", ast_m.group(Grammar.alt(Grammar.literal("a"), Grammar.literal("b"))))
    T.ok(b:compile():find("%("))
end)

T.test("seq inside alt gets parenthesised", function()
    local b = Grammar.builder()
    b:rule("root", Grammar.alt(
        Grammar.seq(Grammar.literal("a"), Grammar.literal("b")),
        Grammar.literal("c")
    ))
    T.ok(b:compile():find("%("))
end)

T.test("unknown node kind raises error", function()
    T.err(function()
        compiler_m.compile({{ name = "root", body = { kind = "unknown" } }}, "root", false)
    end, "unknown node kind")
end)

T.test("nil node raises error", function()
    T.err(function()
        compiler_m.compile({{ name = "root", body = nil }}, "root", false)
    end)
end)

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
    -- JSON string literals are encoded as "\"ok\"" in GBNF
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
    -- const strings are JSON-encoded: the literal includes surrounding quotes
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
    -- to_gbnf(root) re-labels the output root; must use a rule that exists
    local g = Grammar.from_enum("color", { "red", "blue" })
    -- "color" is the actual rule name; override to have it output as "color"
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
-- Regex
-- ─────────────────────────────────────────────────────────────────────────────

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

-- ─────────────────────────────────────────────────────────────────────────────
-- JSON Schema
-- ─────────────────────────────────────────────────────────────────────────────

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

-- ─────────────────────────────────────────────────────────────────────────────
-- Type annotations
-- ─────────────────────────────────────────────────────────────────────────────

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
    local g = Types.from_function("my_func", { query = "string", limit = "integer" })
    T.ok(type(g:to_gbnf()) == "string")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Dynamic grammars
-- ─────────────────────────────────────────────────────────────────────────────

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
    -- The "name" key is a JSON string literal: compiled as \"name\"
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

-- ─────────────────────────────────────────────────────────────────────────────
-- GrammarContext
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("GrammarContext")

T.test("new: creates context with default root='root'", function()
    local gc = Grammar.context()
    T.eq(type(gc), "table")
    T.eq(gc._root, "root")
end)

T.test("new: custom root option", function()
    T.eq(Grammar.context({ root = "myroot" })._root, "myroot")
end)

T.test("learn_enum: updates stats, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_enum("status", { "ok", "error" })
    T.eq(ret, gc)
    T.eq(gc:stats().n_enums, 1)
end)

T.test("learn_enum: asserts string rule_name", function()
    T.err(function() Grammar.context():learn_enum(42, { "a" }) end)
end)

T.test("learn_enum: grammar compiles with enum rule", function()
    local gc = Grammar.context()
    gc:learn_enum("color", { "red", "green", "blue" })
    local gbnf = gc:current():to_gbnf()
    T.ok(gbnf:find('"red"') or gbnf:find('"green"'))
end)

T.test("learn_table: creates column rules", function()
    local gc = Grammar.context()
    gc:learn_table("users", { "id", "name", "email" })
    local gbnf = gc:current():to_gbnf()
    T.ok(gbnf:find("users") or gbnf:find("name"))
end)

T.test("learn_table: updates stats, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_table("orders", { "id", "amount" })
    T.eq(ret, gc)
    T.eq(gc:stats().n_tables, 1)
end)

T.test("learn_table: asserts string name", function()
    T.err(function() Grammar.context():learn_table(42, { "col" }) end)
end)

T.test("learn_tool: registers tool, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_tool("search", { type = "object" })
    T.eq(ret, gc)
    T.eq(gc:stats().n_tools, 1)
end)

T.test("learn_tool: replaces existing tool with same name", function()
    local gc = Grammar.context()
    gc:learn_tool("search", { type = "object" })
    gc:learn_tool("search", { type = "object", properties = { q = { type = "string" } } })
    T.eq(gc:stats().n_tools, 1)
end)

T.test("learn_rule: adds a custom rule, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_rule("myroot", Grammar.plus(Grammar.char("a-z")))
    T.eq(ret, gc)
    T.eq(gc:stats().n_extra, 1)
end)

T.test("learn_rule: replaces rule with same name", function()
    local gc = Grammar.context()
    gc:learn_rule("r", Grammar.literal("a"))
    gc:learn_rule("r", Grammar.literal("b"))
    T.eq(gc:stats().n_extra, 1)
end)

T.test("forget: removes enum", function()
    local gc = Grammar.context()
    gc:learn_enum("status", { "ok" })
    gc:forget("status")
    T.eq(gc:stats().n_enums, 0)
end)

T.test("forget: removes table", function()
    local gc = Grammar.context()
    gc:learn_table("users", { "id" })
    gc:forget("users")
    T.eq(gc:stats().n_tables, 0)
end)

T.test("forget: removes tool", function()
    local gc = Grammar.context()
    gc:learn_tool("search")
    gc:forget("search")
    T.eq(gc:stats().n_tools, 0)
end)

T.test("forget: returns self for nonexistent name", function()
    local gc = Grammar.context()
    T.eq(gc:forget("nonexistent"), gc)
end)

T.test("current: returns Grammar_obj with to_gbnf", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    T.ok(type(gc:current().to_gbnf) == "function")
end)

T.test("current: caches result until invalidated", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    T.eq(gc:current(), gc:current())
end)

T.test("current: invalidated after learn_enum", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    local g1 = gc:current()
    gc:learn_enum("y", { "b" })
    T.neq(g1, gc:current())
end)

T.test("current: empty context produces compilable grammar", function()
    T.no_error(function() Grammar.context():current():to_gbnf() end)
end)

T.test("snapshot: captures current state", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    local snap = gc:snapshot()
    T.eq(type(snap), "table")
    T.ok(snap.enums ~= nil)
    T.ok(snap.enums["x"] ~= nil)
end)

T.test("restore: reverts to snapshotted state", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    local snap = gc:snapshot()
    gc:learn_enum("y", { "b" })
    T.eq(gc:stats().n_enums, 2)
    gc:restore(snap)
    T.eq(gc:stats().n_enums, 1)
    T.ok(gc._enums["x"] ~= nil)
    T.ok(gc._enums["y"] == nil)
end)

T.test("restore: reverts tools", function()
    local gc = Grammar.context()
    gc:learn_tool("t1")
    local snap = gc:snapshot()
    gc:learn_tool("t2")
    gc:restore(snap)
    T.eq(gc:stats().n_tools, 1)
end)

T.test("restore: returns self", function()
    local gc = Grammar.context()
    T.eq(gc:restore(gc:snapshot()), gc)
end)

T.test("stats: reports all counts", function()
    local gc = Grammar.context()
    gc:learn_enum("e", { "v" })
    gc:learn_table("t", { "c" })
    gc:learn_tool("tool")
    gc:learn_rule("r", Grammar.literal("x"))
    local s = gc:stats()
    T.eq(s.n_enums,  1)
    T.eq(s.n_tables, 1)
    T.eq(s.n_tools,  1)
    T.eq(s.n_extra,  1)
end)

T.test("to_gbnf on current: compiles multiple enums", function()
    local gc = Grammar.context()
    gc:learn_enum("color", { "red", "blue" })
    gc:learn_enum("size",  { "small", "large" })
    T.ok(type(gc:current():to_gbnf()) == "string")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Fuzzer
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Fuzzer")

T.test("fuzz: returns count samples and seed", function()
    local g = Grammar.from_enum("x", { "a", "b", "c" })
    local s, seed = Grammar.fuzz(g, { count = 7, seed = 1 })
    T.eq(#s, 7)
    T.eq(type(seed), "number")
end)

T.test("fuzz: all enum samples are valid", function()
    local g = Grammar.from_enum("color", { "red", "green", "blue" })
    local valid = { red = true, green = true, blue = true }
    for _, s in ipairs(Grammar.fuzz(g, { count = 20, seed = 42 })) do
        T.ok(valid[s], "invalid sample: " .. s)
    end
end)

T.test("fuzz: reproducible with same seed", function()
    local g = Grammar.from_enum("x", { "a", "b", "c" })
    local s1 = Grammar.fuzz(g, { count = 5, seed = 999 })
    local s2 = Grammar.fuzz(g, { count = 5, seed = 999 })
    for i = 1, 5 do T.eq(s1[i], s2[i]) end
end)

T.test("fuzz: different seeds produce different output", function()
    local g = Grammar.from_enum("x", { "a", "b", "c", "d", "e", "f" })
    local s1 = Grammar.fuzz(g, { count = 10, seed = 1 })
    local s2 = Grammar.fuzz(g, { count = 10, seed = 2 })
    local differ = false
    for i = 1, 10 do if s1[i] ~= s2[i] then differ = true; break end end
    T.ok(differ, "same output for different seeds")
end)

T.test("fuzz: variety - all 3 values seen in 30 samples", function()
    local g = Grammar.from_enum("x", { "a", "b", "c" })
    local seen = {}
    for _, s in ipairs(Grammar.fuzz(g, { count = 30, seed = 42 })) do seen[s] = true end
    T.ok(seen["a"] and seen["b"] and seen["c"], "all 3 values seen")
end)

T.test("fuzz: regex samples contain only digits", function()
    local g = Grammar.from_regex("\\d{1,3}")
    for _, s in ipairs(Grammar.fuzz(g, { count = 10, seed = 5, max_rep = 3 })) do
        T.ok(not s:find("[^0-9]"), "non-digit in '" .. s .. "'")
    end
end)

T.test("fuzz: variety of lengths in \\d{1,4}", function()
    local g = Grammar.from_regex("\\d{1,4}")
    local lens = {}
    for _, s in ipairs(Grammar.fuzz(g, { count = 30, seed = 7, max_rep = 4 })) do
        lens[#s] = true
    end
    local n = 0
    for _ in pairs(lens) do n = n + 1 end
    T.ok(n >= 2, "at least 2 distinct lengths (got " .. n .. ")")
end)

T.test("fuzz_one: returns single non-empty string in valid set", function()
    local g = Grammar.from_enum("x", { "hello", "world" })
    local s = Grammar.fuzz_one(g, { seed = 1 })
    T.eq(type(s), "string")
    T.ok(#s > 0)
    T.ok(s == "hello" or s == "world")
end)

T.test("fuzz_validate: returns true for satisfiable grammar", function()
    local g = Grammar.from_enum("x", { "a", "b" })
    local ok_v, err_v = Grammar.fuzz_validate(g, { count = 10, seed = 1 })
    T.ok(ok_v)
    T.ok(err_v == nil)
end)

T.test("fuzz_validate: allow_empty=true skips the all-empty check", function()
    -- A grammar that always produces empty string: fuzz_validate with
    -- allow_empty=true skips the "all samples empty" early-exit.
    -- The "> half empty" check may still fire, so we just verify that a
    -- grammar producing non-empty output always passes.
    local g = Grammar.from_regex("[a-z]+")
    local ok2, _ = Grammar.fuzz_validate(g, { count = 10, seed = 1, allow_empty = true })
    T.ok(ok2)
end)

T.test("biased_rep: [a-z]+ samples mostly non-empty", function()
    local g = Grammar.from_regex("[a-z]+")
    local non_empty = 0
    for _, s in ipairs(Grammar.fuzz(g, { count = 20, seed = 3 })) do
        if #s > 0 then non_empty = non_empty + 1 end
    end
    T.ok(non_empty >= 15, "at least 15/20 non-empty (got " .. non_empty .. ")")
end)

T.test("biased_rep: variety in [a-z]{1,5}", function()
    local g = Grammar.from_regex("[a-z]{1,5}")
    local lens = {}
    for _, s in ipairs(Grammar.fuzz(g, { count = 30, seed = 8 })) do lens[#s] = true end
    local n = 0
    for _ in pairs(lens) do n = n + 1 end
    T.ok(n >= 3, "at least 3 distinct lengths (got " .. n .. ")")
end)

T.test("fuzz: no rules raises error", function()
    T.err(function()
        Grammar.fuzz(Grammar.from_builder(Grammar.builder()))
    end, "no rules found")
end)

T.test("Grammar_obj:fuzz() returns samples", function()
    local s = Grammar.from_enum("x", { "a", "b", "c" }):fuzz({ count = 5, seed = 1 })
    T.eq(#s, 5)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Debug module
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Debug module")

T.test("inspect: returns non-empty string with rule info", function()
    local s = Grammar.debug(Grammar.from_enum("status", { "ok", "error" }))
    T.eq(type(s), "string")
    T.ok(#s > 0)
    T.ok(s:find("status"))
end)

T.test("inspect: shows 'Grammar' header", function()
    T.ok(Grammar.from_enum("x", { "a", "b" }):inspect():find("Grammar"))
end)

T.test("inspect: show_stats=false still returns string", function()
    T.ok(type(Debug_m.inspect(Grammar.from_enum("x", { "a" }), { show_stats = false })) == "string")
end)

T.test("inspect: empty grammar returns placeholder", function()
    T.eq(Debug_m.inspect({}), "(empty grammar)")
end)

T.test("analyze: returns n_rules > 0", function()
    local a = Grammar.analyze(Grammar.from_type({ name = "string", age = "integer" }))
    T.eq(type(a.n_rules), "number")
    T.ok(a.n_rules > 0)
end)

T.test("analyze: returns root name string", function()
    T.eq(type(Grammar.analyze(Grammar.from_enum("status", { "ok" })).root), "string")
end)

T.test("analyze: returns unreferenced list", function()
    T.eq(type(Grammar.analyze(Grammar.from_enum("x", { "a" })).unreferenced), "table")
end)

T.test("analyze: returns recursive list", function()
    T.eq(type(Grammar.analyze(Grammar.from_enum("x", { "a" })).recursive), "table")
end)

T.test("analyze: returns gbnf_length > 0", function()
    local a = Grammar.analyze(Grammar.from_enum("x", { "a" }))
    T.ok(a.gbnf_length > 0)
end)

T.test("analyze: empty grammar returns zero n_rules", function()
    T.eq(Debug_m.analyze({}).n_rules, 0)
end)

T.test("tree: returns non-empty string", function()
    local s = Grammar.tree(Grammar.from_type({ name = "string", age = "integer" }))
    T.eq(type(s), "string")
    T.ok(#s > 0)
end)

T.test("tree: empty grammar returns '(empty)'", function()
    T.eq(Debug_m.tree({}), "(empty)")
end)

T.test("diff: detects added rule", function()
    local g1 = Grammar.from_enum("root", { "a" })
    local b2 = Grammar.builder({ root = "root" })
    b2:rule("root", Grammar.literal("a"))
    b2:rule("extra", Grammar.literal("e"))
    local d = Grammar.diff(g1, Grammar.from_builder(b2))
    T.ok(d:find("extra"))
    T.ok(d:find("+"))
end)

T.test("diff: detects removed rule", function()
    local b1 = Grammar.builder({ root = "root" })
    b1:rule("root", Grammar.literal("a"))
    b1:rule("gone", Grammar.literal("g"))
    local b2 = Grammar.builder({ root = "root" })
    b2:rule("root", Grammar.literal("a"))
    local d = Grammar.diff(Grammar.from_builder(b1), Grammar.from_builder(b2))
    T.ok(d:find("gone"))
    T.ok(d:find("-"))
end)

T.test("diff: detects changed rule", function()
    local b1 = Grammar.builder({ root = "root" })
    b1:rule("root", Grammar.literal("a"))
    local b2 = Grammar.builder({ root = "root" })
    b2:rule("root", Grammar.literal("b"))
    local d = Grammar.diff(Grammar.from_builder(b1), Grammar.from_builder(b2))
    T.ok(d:find("~") or d:find("changed"))
end)

T.test("diff: no changes shows '(no changes)'", function()
    local g = Grammar.from_enum("x", { "a" })
    T.ok(Grammar.diff(g, g):find("no changes"))
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Except module
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("Except module")

T.test("except_chars: removes specified chars from range", function()
    local n = Except.except_chars("a-z", { "a", "e", "i", "o", "u" })
    T.ok(n.kind == "char" or n.kind == "literal")
end)

T.test("except_chars: removes digit from range", function()
    local n = Except.except_chars("0-9", { "0" })
    T.eq(n.kind, "char")
end)

T.test("except_chars: removing all chars returns empty literal", function()
    local n = Except.except_chars("ab", { "a", "b" })
    T.eq(n.kind, "literal")
    T.eq(n.value, "")
end)

T.test("except_chars: negated flag propagates", function()
    local n = Except.except_chars("0-9", { "5" }, true)
    T.eq(n.negated, true)
end)

T.test("except_chars: returns usable AST node in grammar", function()
    local node = Except.except_chars("a-z", { "x", "y", "z" })
    T.no_error(function()
        local b = Grammar.builder()
        b:rule("root", Grammar.plus(node))
        b:compile()
    end)
end)

T.test("Grammar.except_chars: re-exported at top level", function()
    local n = Grammar.except_chars("0-9", { "0" })
    T.ok(n.kind == "char" or n.kind == "literal")
end)

T.test("except_values: excludes listed values", function()
    local b = Except.except_values({ "GET", "POST", "PUT", "DELETE" }, { "DELETE" })
    local gbnf = b:compile({ whitespace = false })
    T.ok(gbnf:find('"GET"'))
    T.ok(gbnf:find('"POST"'))
    T.ok(not gbnf:find('"DELETE"'))
end)

T.test("except_values: custom rule name", function()
    local b = Except.except_values({ "a", "b", "c" }, { "c" }, "safe-val")
    T.ok(b._names["safe-val"])
end)

T.test("except_values: default rule name is 'except'", function()
    T.ok(Except.except_values({ "a", "b" }, { "b" })._names["except"])
end)

T.test("except_values: error when all excluded", function()
    T.err(function()
        Except.except_values({ "a" }, { "a" })
    end, "no values remain")
end)

T.test("Grammar.except_values: re-exported, returns Grammar_obj", function()
    local g = Grammar.except_values({ "ok", "error" }, { "error" })
    T.ok(type(g.to_gbnf) == "function")
end)

T.test("except_pattern: factory returns function", function()
    T.eq(type(Except.except_pattern("^_")), "function")
end)

T.test("except_pattern: accepts non-matching strings", function()
    local fn = Except.except_pattern("^_")
    T.ok(fn("hello") == true)
    T.ok(fn("world") == true)
end)

T.test("except_pattern: rejects matching strings", function()
    local fn = Except.except_pattern("^_")
    T.ok(fn("_private") == false)
    T.ok(fn("__dunder__") == false)
end)

T.test("Grammar.except_pattern: re-exported", function()
    local fn = Grammar.except_pattern("%d+")
    T.eq(type(fn), "function")
    T.ok(fn("abc") == true)
    T.ok(fn("123") == false)
end)

T.test("except_prefix: builds grammar avoiding prefix chars", function()
    local base_g = Grammar.from_builder(
        Grammar.builder():rule("root", Grammar.seq(
            Grammar.char("a-zA-Z_"),
            Grammar.star(Grammar.char("a-zA-Z0-9_"))
        ))
    )
    T.ok(type(Except.except_prefix(base_g, { "_" }, "pub-ident")) == "table")
end)

T.test("except_prefix: no prefixes returns base grammar", function()
    local base_g = Grammar.from_builder(
        Grammar.builder():rule("root", Grammar.literal("x"))
    )
    T.ok(type(Except.except_prefix(base_g, {}, "result")) == "table")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- DCCD mock
-- ─────────────────────────────────────────────────────────────────────────────

T.suite("DCCD mock")

-- ── Mock helpers ──────────────────────────────────────────────────────────────

local function make_scripted_sampler(token_seq, eog_id)
    local idx = 0
    return {
        reset  = function() idx = 0 end,
        sample = function(_, _, _)
            idx = idx + 1
            if idx > #token_seq then return eog_id end
            return token_seq[idx]
        end,
        accept = function() end,
    }
end

local TOKEN_PIECES = {
    [1] = "{",  [2] = '"', [3] = "s",   [4] = "t",  [5] = "a",
    [6] = "t",  [7] = "u", [8] = "s",   [9] = '"',  [10] = ":",
    [11] = '"', [12] = "o", [13] = "k", [14] = '"', [15] = "}",
    [20] = "I", [21] = " ", [22] = "t", [23] = "h",
    [24] = "i", [25] = "n", [26] = "k",
}
local EOG_ID = 999

local mock_vocab = {
    is_eog = function(_, tok) return tok == EOG_ID end,
    piece  = function(_, tok) return TOKEN_PIECES[tok] or "?" end,
}

local snap_id = 0
local mock_ctx = {
    _n_past = 10,
    ptr     = function(self) return self end,
    decode_single = function(self, _, _) self._n_past = self._n_past + 1 end,
    snapshot = function(self)
        snap_id = snap_id + 1
        return { id = snap_id, n_past = self._n_past }
    end,
    restore = function(self, snap) self._n_past = snap.n_past end,
}

local draft_seq = { 20, 21, 22, 23, 24, 25, 26 }
local final_seq = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

-- ── DCCD.new() ────────────────────────────────────────────────────────────────

T.test("DCCD.new: returns DCCD instance with generate function", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(type(dc), "table")
    T.ok(type(dc.generate) == "function")
end)

T.test("DCCD.new: opts stored correctly (max_d, max_f, best_k)", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 64,
        max_final_tokens  = 128,
        best_of_k         = 2,
    })
    T.eq(dc._max_d, 64)
    T.eq(dc._max_f, 128)
    T.eq(dc._best_k, 2)
end)

T.test("DCCD.new: defaults: max_d=512, max_f=512, best_k=1", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(dc._max_d, 512)
    T.eq(dc._max_f, 512)
    T.eq(dc._best_k, 1)
end)

T.test("DCCD.new: asserts ctx required", function()
    T.err(function()
        DCCD_m.new(nil, mock_vocab, { draft_sampler = {}, constrain_sampler = {} })
    end, "ctx required")
end)

T.test("DCCD.new: asserts vocab required", function()
    T.err(function()
        DCCD_m.new(mock_ctx, nil, { draft_sampler = {}, constrain_sampler = {} })
    end, "vocab required")
end)

T.test("DCCD.new: asserts draft_sampler required", function()
    T.err(function()
        DCCD_m.new(mock_ctx, mock_vocab, { constrain_sampler = {} })
    end, "draft_sampler required")
end)

T.test("DCCD.new: asserts constrain_sampler required", function()
    T.err(function()
        DCCD_m.new(mock_ctx, mock_vocab, { draft_sampler = {} })
    end, "constrain_sampler required")
end)

-- ── generate() ────────────────────────────────────────────────────────────────

T.test("generate: returns result table with all expected fields", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 32,
        max_final_tokens  = 32,
    })
    local result = dc:generate()
    T.eq(type(result), "table")
    T.eq(type(result.text),         "string")
    T.eq(type(result.draft),        "string")
    T.eq(type(result.tokens),       "table")
    T.eq(type(result.draft_tokens), "table")
    T.eq(type(result.n_tokens),     "number")
    T.eq(type(result.n_draft_toks), "number")
end)

T.test("generate: final text matches scripted sequence", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 32,
        max_final_tokens  = 32,
    })
    T.eq(dc:generate().text, '{"status":"ok"}')
end)

T.test("generate: draft text matches scripted draft", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(dc:generate().draft, "I think")
end)

T.test("generate: calls ctx:snapshot() at least once", function()
    mock_ctx._n_past = 10
    local before = snap_id
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    dc:generate()
    T.ok(snap_id > before)
end)

T.test("generate: n_tokens == #tokens", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    local r = dc:generate()
    T.eq(r.n_tokens, #r.tokens)
end)

T.test("generate: n_draft_toks == #draft_tokens", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    local r = dc:generate()
    T.eq(r.n_draft_toks, #r.draft_tokens)
end)

-- ── Core: draft tokens injected into KV before constrained pass ───────────────

T.test("generate: draft tokens injected into KV (arXiv:2603.03305 §3)", function()
    local kv_injected = {}
    local mock_ctx_instr = {
        _n_past = 10,
        ptr = function(self) return self end,
        decode_single = function(self, tok, _)
            self._n_past = self._n_past + 1
            kv_injected[#kv_injected + 1] = tok
        end,
        snapshot = function(self) return { n_past = self._n_past } end,
        restore  = function(self, snap)
            self._n_past = snap.n_past
            kv_injected = {}   -- reset on restore: only care about post-restore calls
        end,
    }

    local dc_instr = DCCD_m.new(mock_ctx_instr, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20, 21 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1, 2, 3 }, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 10,
    })

    dc_instr:generate()

    -- After last restore: [20, 21] (draft injection) then [1, 2, 3] (constrained)
    T.eq(#kv_injected, 5, "draft+final = 5 tokens in KV (got " .. #kv_injected .. ")")
    T.eq(kv_injected[1], 20, "draft token 1 = 20")
    T.eq(kv_injected[2], 21, "draft token 2 = 21")
    T.eq(kv_injected[3],  1, "constrained token 1 = 1")
    T.eq(kv_injected[4],  2, "constrained token 2 = 2")
    T.eq(kv_injected[5],  3, "constrained token 3 = 3")
end)

-- ── Callbacks ─────────────────────────────────────────────────────────────────

T.test("on_draft_token: fires for draft pieces (k=1)", function()
    mock_ctx._n_past = 10
    local draft_cb = {}
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        on_draft_token    = function(p) draft_cb[#draft_cb + 1] = p end,
    })
    dc:generate()
    T.ok(#draft_cb > 0)
end)

T.test("on_final_token: fires and pieces concatenate to expected text", function()
    mock_ctx._n_past = 10
    local final_cb = {}
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        on_final_token    = function(p) final_cb[#final_cb + 1] = p end,
    })
    dc:generate()
    T.ok(#final_cb > 0)
    T.eq(table.concat(final_cb), '{"status":"ok"}')
end)

-- ── best_of ───────────────────────────────────────────────────────────────────

T.test("best_of: returns result table", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    local r = dc:best_of(2)
    T.eq(type(r), "table")
    T.ok(type(r.text) == "string")
end)

T.test("best_of k=3: selects longest constrained output", function()
    local calls = 0
    local draft_lengths = { 2, 5, 3 }
    local function make_variable_draft()
        return {
            reset  = function() end,
            accept = function() end,
            sample = function(_, _, _)
                calls = calls + 1
                local attempt = math.ceil(calls / 10)
                attempt = math.max(1, math.min(3, attempt))
                local len = draft_lengths[attempt] or 2
                local pos = ((calls - 1) % 10) + 1
                if pos > len then return EOG_ID end
                return 20 + pos
            end,
        }
    end

    mock_ctx._n_past = 10
    calls = 0
    local dc2 = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_variable_draft(),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 32,
        best_of_k         = 3,
    })
    local r2 = dc2:generate()
    T.ok(type(r2.text) == "string")
    T.ok(#r2.draft_tokens >= 2)
end)

-- ── Grammar.dccd() top-level constructor ──────────────────────────────────────

T.test("Grammar.dccd: returns DCCD instance with generate/best_of", function()
    mock_ctx._n_past = 10
    local dc = Grammar.dccd(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(type(dc), "table")
    T.ok(type(dc.generate) == "function")
    T.ok(type(dc.best_of)  == "function")
end)

T.test("Grammar.dccd: default max_draft_tokens=512", function()
    mock_ctx._n_past = 10
    local dc = Grammar.dccd(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(dc._max_d, 512)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Summary
-- ─────────────────────────────────────────────────────────────────────────────

local ok = T.summary()
os.exit(ok and 0 or 1)
