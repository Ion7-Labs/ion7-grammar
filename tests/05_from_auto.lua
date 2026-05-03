#!/usr/bin/env luajit
--- @module tests.05_from_auto
--- @author  ion7 / Ion7 Project Contributors
---
--- `Grammar.from_auto` — heuristic format detection.
---
--- Coverage :
---   - Routes JSON-Schema input ({...}) to from_json_schema.
---   - Routes EBNF (::=) input to from_ebnf.
---   - Routes ABNF (name = body) input to from_abnf.
---   - Falls back to from_regex for everything else.

require "tests.helpers"

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"

T.suite("Grammar.from_auto — JSON Schema detection")

T.test("input starting with { routes to from_json_schema", function()
    local g = Grammar.from_auto([[{"type":"integer"}]])
    -- A JSON Schema integer compiles to a numeric pattern.
    T.contains(g:to_gbnf(), "[0-9]")
end)

T.test("leading whitespace is tolerated", function()
    local g = Grammar.from_auto([[

       {"type":"boolean"}
    ]])
    T.contains(g:to_gbnf(), '"true"')
end)

T.suite("Grammar.from_auto — EBNF detection")

T.test("input containing ::= routes to from_ebnf", function()
    local g = Grammar.from_auto([[
Date ::= Year
Year ::= [0-9]+
]])
    T.contains(g:to_gbnf(), "date ::=")
end)

T.test("EBNF with hex codes survives auto-detect", function()
    local g = Grammar.from_auto([[
hi ::= #x48 #x69
]])
    T.contains(g:to_gbnf(), '"H"')
end)

T.suite("Grammar.from_auto — ABNF detection")

T.test("input with name = body lines routes to from_abnf", function()
    local g = Grammar.from_auto([[
date = year "-" month
year = 4DIGIT
month = 2DIGIT
]])
    T.contains(g:to_gbnf(), "date ::=")
end)

T.test("ABNF with %x ranges survives auto-detect", function()
    local g = Grammar.from_auto([[
ascii = %x41-5A
]])
    T.contains(g:to_gbnf(), "[\\x41-\\x5a]")
end)

T.suite("Grammar.from_auto — regex fallback")

T.test("a plain regex pattern routes to from_regex", function()
    local g = Grammar.from_auto("\\d{4}-\\d{2}-\\d{2}")
    T.contains(g:to_gbnf(), "[0-9]")
end)

T.test("char class in a single line routes to regex", function()
    local g = Grammar.from_auto("[a-zA-Z0-9_]+")
    T.contains(g:to_gbnf(), "[a-zA-Z0-9_]+")
end)

T.test("a literal-only pattern routes to regex", function()
    local g = Grammar.from_auto("hello")
    T.contains(g:to_gbnf(), '"hello"')
end)

T.suite("Grammar.from_auto — type errors")

T.test("non-string input raises", function()
    T.err(function() Grammar.from_auto({}) end, "string")
    T.err(function() Grammar.from_auto(42) end, "string")
end)

local ok = T.summary()
os.exit(ok and 0 or 1)
