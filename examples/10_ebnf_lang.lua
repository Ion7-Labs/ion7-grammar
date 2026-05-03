--- examples/10_ebnf_lang.lua
--- ion7-grammar — `Grammar.from_ebnf` driving a small DSL.
---
--- Builds two W3C-style EBNF grammars (arithmetic expressions and a
--- minimal JSON), compiles each to GBNF, fuzzes them. Demonstrates the
--- shape of grammar inputs you can copy-paste straight from a W3C spec
--- (XML, JSON, SVG, XPath, …).
---
--- Run:
---   luajit examples/10_ebnf_lang.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grammar = require "ion7.grammar"

local function section(title)
    io.write("\n── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

-- ── 1. Arithmetic expression grammar ──────────────────────────────────────────
-- Recursive descent flavour : expr → term → factor → expr.

local arith = Grammar.from_ebnf([[
expr   ::= term (("+" | "-") term)*
term   ::= factor (("*" | "/") factor)*
factor ::= number | "(" expr ")"
number ::= [0-9]+
]])

section("Arithmetic expression DSL")
io.write(arith:to_gbnf())
io.write("\n")

io.write("\n  fuzz samples (tight depth + rep — recursive grammars explode otherwise):\n")
for _, s in ipairs(Grammar.fuzz(arith, { count = 5, seed = 13, max_depth = 5, max_rep = 2 })) do
    io.write("    " .. s .. "\n")
end

-- ── 2. Minimal JSON value grammar ─────────────────────────────────────────────
-- The shape closely mirrors the JSON grammar in RFC 8259 written in
-- W3C-style EBNF for ease of copying out of an HTML spec.

local json_min = Grammar.from_ebnf([[
value      ::= object | array | string | number | "true" | "false" | "null"
object     ::= "{" "}" | "{" pair ("," pair)* "}"
pair       ::= string ":" value
array      ::= "[" "]" | "[" value ("," value)* "]"
string     ::= #x22 [a-zA-Z0-9 ]* #x22
number     ::= [0-9]+
]])

section("Minimal JSON")
io.write(json_min:to_gbnf())
io.write("\n")

io.write("\n  fuzz samples:\n")
for _, s in ipairs(Grammar.fuzz(json_min, { count = 4, seed = 17, max_depth = 4, max_rep = 2 })) do
    io.write("    " .. s .. "\n")
end

-- ── 3. Auto-detect ergonomics ─────────────────────────────────────────────────
-- `from_auto` recognises the W3C `::=` separator and routes to from_ebnf.

section("from_auto routes EBNF input automatically")
local auto_g = Grammar.from_auto([[
greeting ::= "Hello, " name "!"
name     ::= [A-Z][a-z]+
]])
io.write(auto_g:to_gbnf())
io.write("\n")

io.write("\n══ done ════════════════════════════════════════════════════════\n")
