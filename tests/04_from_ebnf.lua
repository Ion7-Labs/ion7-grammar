#!/usr/bin/env luajit
--- @module tests.04_from_ebnf
--- @author  ion7 / Ion7 Project Contributors
---
--- W3C-style EBNF — `Grammar.from_ebnf` constructor.
---
--- Coverage :
---   - `::=` rule definitions, multi-line bodies via `|`
---   - String literals (single + double quoted)
---   - Hex char codes (`#xNN`)
---   - Char classes (regex-style with `^` negation)
---   - Postfix quantifiers `?`, `*`, `+`
---   - Alternation `|`, group `( ... )`
---   - Block comments `/* ... */`
---   - Errors on the unsupported forms (difference operator)

require "tests.helpers"

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"

T.suite("Grammar.from_ebnf — basic parsing")

T.test("compiles a single-rule grammar", function()
    local g = Grammar.from_ebnf('greet ::= "hello"\n')
    T.ok(g:to_gbnf():find('"hello"', 1, true))
end)

T.test("first rule becomes the root by default", function()
    local g = Grammar.from_ebnf([[
Date  ::= Year "-" Month
Year  ::= [0-9]+
Month ::= [0-9]+
]])
    local first_line = g:to_gbnf():match("[^\n]+")
    T.contains(first_line, "date")
end)

T.test("explicit root override", function()
    local g = Grammar.from_ebnf([[
Date  ::= Year
Year  ::= [0-9]+
]], "Year")
    local first_line = g:to_gbnf():match("[^\n]+")
    T.contains(first_line, "year")
end)

T.test("multi-line body via | continuation", function()
    local g = Grammar.from_ebnf([[
status ::= "ok"
        | "error"
        | "pending"
]])
    T.contains(g:to_gbnf(), "|")
end)

T.suite("Grammar.from_ebnf — string literals")

T.test("double-quoted string", function()
    local g = Grammar.from_ebnf('hi ::= "Hello"\n')
    T.contains(g:to_gbnf(), '"Hello"')
end)

T.test("single-quoted string", function()
    local g = Grammar.from_ebnf("hi ::= 'Hello'\n")
    T.contains(g:to_gbnf(), '"Hello"')
end)

T.test("hex char code", function()
    local g = Grammar.from_ebnf("a ::= #x41\n")
    T.contains(g:to_gbnf(), '"A"')
end)

T.suite("Grammar.from_ebnf — char classes")

T.test("simple char class", function()
    local g = Grammar.from_ebnf("digit ::= [0-9]\n")
    T.contains(g:to_gbnf(), "[0-9]")
end)

T.test("multi-range class", function()
    local g = Grammar.from_ebnf("alnum ::= [a-zA-Z0-9]\n")
    T.contains(g:to_gbnf(), "[a-zA-Z0-9]")
end)

T.test("negated char class", function()
    local g = Grammar.from_ebnf("nonws ::= [^ \\t\\n]\n")
    T.contains(g:to_gbnf(), "[^")
end)

T.suite("Grammar.from_ebnf — quantifiers")

T.test("? quantifier", function()
    local g = Grammar.from_ebnf("opt ::= [a-z]?\n")
    T.contains(g:to_gbnf(), "?")
end)

T.test("* quantifier", function()
    local g = Grammar.from_ebnf("any ::= [a-z]*\n")
    T.contains(g:to_gbnf(), "*")
end)

T.test("+ quantifier", function()
    local g = Grammar.from_ebnf("nonempty ::= [a-z]+\n")
    T.contains(g:to_gbnf(), "+")
end)

T.suite("Grammar.from_ebnf — composition")

T.test("alternation with |", function()
    local g = Grammar.from_ebnf('ab ::= "a" | "b"\n')
    T.contains(g:to_gbnf(), "|")
end)

T.test("group with parentheses", function()
    local g = Grammar.from_ebnf('g ::= ("a" | "b") "!"\n')
    T.contains(g:to_gbnf(), "(")
end)

T.suite("Grammar.from_ebnf — comments")

T.test("/* ... */ block comments are stripped", function()
    local g = Grammar.from_ebnf([[
/* the date format */
Date ::= Year "-" Month  /* trailing comment */
Year ::= [0-9]+
Month ::= [0-9]+
]])
    T.contains(g:to_gbnf(), "date ::=")
end)

T.suite("Grammar.from_ebnf — JSON-spec excerpt smoke test")

T.test("JSON-like grammar compiles", function()
    local g = Grammar.from_ebnf([[
value      ::= object | array | string | number | "true" | "false" | "null"
object     ::= "{" "}" | "{" members "}"
members    ::= pair | pair "," members
pair       ::= string ":" value
array      ::= "[" "]" | "[" elements "]"
elements   ::= value | value "," elements
string     ::= [a-zA-Z]+
number     ::= [0-9]+
]])
    T.no_error(function() g:to_gbnf() end)
    T.contains(g:to_gbnf(), "value ::=")
end)

T.suite("Grammar.from_ebnf — rejects unsupported forms")

T.test("difference operator (A - B) raises", function()
    T.err(function()
        Grammar.from_ebnf('chars ::= [a-z] - "z"\n')
    end, "difference")
end)

local ok = T.summary()
os.exit(ok and 0 or 1)
