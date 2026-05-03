#!/usr/bin/env luajit
--- @module tests.03_from_abnf
--- @author  ion7 / Ion7 Project Contributors
---
--- ABNF (RFC 5234 §4) — `Grammar.from_abnf` constructor.
---
--- Coverage :
---   - Rule definitions and references
---   - Repetition forms : `*element`, `1*5element`, `3element`
---   - Quoted strings, %x / %d / %b numeric values, ranges, dot-concat
---   - Optional `[ ... ]`, group `( ... )`, alternation with `/`
---   - Built-in core rules (ALPHA, DIGIT, …) injected lazily
---   - Comments and multi-line bodies
---   - Errors on the unsupported forms (incremental alt, prose values)

require "tests.helpers"

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"

T.suite("Grammar.from_abnf — basic parsing")

T.test("compiles a single-rule grammar", function()
    local g = Grammar.from_abnf("greeting = \"hello\"\n")
    T.ok(g:to_gbnf():find('"hello"', 1, true))
end)

T.test("returns a Grammar_obj with rules() and to_gbnf()", function()
    local g = Grammar.from_abnf("root = ALPHA\n")
    T.is_type(g.rules,   "function")
    T.is_type(g.to_gbnf, "function")
end)

T.test("first rule becomes the root by default", function()
    local g = Grammar.from_abnf([[
date = year "-" month
year = 4DIGIT
month = 2DIGIT
]])
    -- The compiler always emits the root first.
    local first_line = g:to_gbnf():match("[^\n]+")
    T.contains(first_line, "date")
end)

T.test("explicit root override", function()
    local g = Grammar.from_abnf([[
date = year
year = 2DIGIT
]], "year")
    local first_line = g:to_gbnf():match("[^\n]+")
    T.contains(first_line, "year")
end)

T.suite("Grammar.from_abnf — repetition forms")

T.test("'4DIGIT' produces fixed repetition", function()
    local g = Grammar.from_abnf("year = 4DIGIT\n")
    T.contains(g:to_gbnf(), "{4}")
end)

T.test("'1*3DIGIT' produces a {1,3} bound", function()
    local g = Grammar.from_abnf("octet = 1*3DIGIT\n")
    T.contains(g:to_gbnf(), "{1,3}")
end)

T.test("'*DIGIT' produces zero-or-more", function()
    local g = Grammar.from_abnf("frag = *DIGIT\n")
    T.contains(g:to_gbnf(), "*")
end)

T.test("'1*DIGIT' produces one-or-more", function()
    local g = Grammar.from_abnf("frag = 1*DIGIT\n")
    T.contains(g:to_gbnf(), "+")
end)

T.suite("Grammar.from_abnf — strings and numeric values")

T.test("hex single byte renders as a literal char or escape", function()
    local g = Grammar.from_abnf("a = %x41\n")
    T.contains(g:to_gbnf(), '"A"')
end)

T.test("hex range renders as a char class", function()
    local g = Grammar.from_abnf("ascii = %x41-5A\n")
    T.contains(g:to_gbnf(), "[\\x41-\\x5a]")
end)

T.test("hex dot-concat renders as a single literal", function()
    local g = Grammar.from_abnf("hi = %x48.65.6C.6C.6F\n")
    T.contains(g:to_gbnf(), '"Hello"')
end)

T.test("decimal value", function()
    local g = Grammar.from_abnf("a = %d65\n")
    T.contains(g:to_gbnf(), '"A"')
end)

T.test("binary value", function()
    local g = Grammar.from_abnf("a = %b01000001\n")
    T.contains(g:to_gbnf(), '"A"')
end)

T.suite("Grammar.from_abnf — composition")

T.test("alternation with /", function()
    local g = Grammar.from_abnf("ab = \"a\" / \"b\"\n")
    T.contains(g:to_gbnf(), "|")
end)

T.test("group with parentheses", function()
    local g = Grammar.from_abnf("g = ( \"a\" / \"b\" ) \"!\"\n")
    T.contains(g:to_gbnf(), "(")
end)

T.test("optional with brackets", function()
    local g = Grammar.from_abnf("opt = \"a\" [ \"b\" ]\n")
    T.contains(g:to_gbnf(), "?")
end)

T.suite("Grammar.from_abnf — core rules")

T.test("DIGIT is injected only when referenced", function()
    local g = Grammar.from_abnf("root = 4DIGIT\n")
    T.contains(g:to_gbnf(), "digit ::= [0-9]")
end)

T.test("ALPHA is injected only when referenced", function()
    local g = Grammar.from_abnf("root = 1*ALPHA\n")
    T.contains(g:to_gbnf(), "alpha ::= [A-Za-z]")
end)

T.test("HEXDIG / WSP / CRLF / DQUOTE are absent when unused", function()
    local g = Grammar.from_abnf("root = \"x\"\n")
    local gbnf = g:to_gbnf()
    T.eq(gbnf:find("hexdig") == nil, true)
    T.eq(gbnf:find("wsp")    == nil, true)
    T.eq(gbnf:find("crlf")   == nil, true)
    T.eq(gbnf:find("dquote") == nil, true)
end)

T.test("user redefinition shadows core rule", function()
    local g = Grammar.from_abnf([[
root = 4DIGIT
DIGIT = "0" / "1"
]])
    -- The user-defined DIGIT replaces the core character class.
    T.contains(g:to_gbnf(), '"0" | "1"')
end)

T.suite("Grammar.from_abnf — comments and layout")

T.test("comments are stripped", function()
    local g = Grammar.from_abnf([[
; This is the date format
date = year "-" month
; year part
year = 4DIGIT
month = 2DIGIT
]])
    T.contains(g:to_gbnf(), "date ::=")
end)

T.test("multi-line bodies via line continuation", function()
    local g = Grammar.from_abnf([[
choice = "a"
       / "b"
       / "c"
]])
    T.contains(g:to_gbnf(), "|")
end)

T.suite("Grammar.from_abnf — rejects unsupported forms")

T.test("incremental alternative (=/) raises", function()
    T.err(function()
        Grammar.from_abnf([[
root = "a"
root =/ "b"
]])
    end, "incremental")
end)

T.test("prose value (<...>) raises", function()
    T.err(function()
        Grammar.from_abnf("root = <some prose>\n")
    end, "prose")
end)

local ok = T.summary()
os.exit(ok and 0 or 1)
