--- SPDX-License-Identifier: MIT
--- ion7-grammar — AST, Builder, Compiler tests.
---
--- Run standalone:  luajit tests/spec/test_ast.lua
--- Or via runner:   luajit tests/test_pure.lua
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local T          = require "tests.framework"
local Grammar    = require "ion7.grammar"
local ast_m      = require "ion7.grammar.ast"
local compiler_m = require "ion7.grammar.ast.compiler"

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
-- Standalone runner
-- ─────────────────────────────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:find("test_ast") then
    local ok = T.summary()
    os.exit(ok and 0 or 1)
end
