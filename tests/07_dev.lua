--- SPDX-License-Identifier: MIT
--- ion7-grammar — dev tools tests (Fuzzer, Debug, Except).
---
--- Run standalone:  luajit tests/spec/test_dev.lua
--- Or via runner:   luajit tests/test_pure.lua
require "tests.helpers"

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"
local Debug_m = require "ion7.grammar.dev.debug"
local Except  = require "ion7.grammar.except"

-- Fuzzer

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

-- Debug module

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

-- Except module

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

local ok = T.summary()
os.exit(ok and 0 or 1)
