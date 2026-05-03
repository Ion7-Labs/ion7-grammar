#!/usr/bin/env luajit
--- @module tests.00_modules
--- @author  ion7 / Ion7 Project Contributors
---
--- Module-load sanity. Confirms that every public sub-module of
--- `ion7.grammar` requires successfully under the current LuaJIT
--- runtime. If this file fails, every other suite will fail too — we
--- run it first so the noise above the real failure stays minimal.

require "tests.helpers"

local T = require "tests.framework"

T.suite("ion7.grammar — module load")

T.test("require 'ion7.grammar' succeeds", function()
    T.no_error(function() require "ion7.grammar" end)
end)

T.test("Grammar._VERSION is a non-empty string", function()
    local Grammar = require "ion7.grammar"
    T.is_type(Grammar._VERSION, "string")
    T.gt(#Grammar._VERSION, 0)
end)

T.test("Grammar.null sentinel exists and round-trips by identity", function()
    local Grammar = require "ion7.grammar"
    T.neq(Grammar.null, nil)
    -- The same value must be re-exported from from.json
    local json_mod = require "ion7.grammar.from.json"
    T.eq(Grammar.null, json_mod.null)
end)

T.suite("ion7.grammar — sub-module loads")

local sub_modules = {
    "ion7.grammar.ast",
    "ion7.grammar.ast.builder",
    "ion7.grammar.ast.compiler",
    "ion7.grammar.ast.nodes",
    "ion7.grammar.ast.walk",
    "ion7.grammar.compose",
    "ion7.grammar.except",
    "ion7.grammar.grammar_obj",
    "ion7.grammar.from.regex",
    "ion7.grammar.from.abnf",
    "ion7.grammar.from.ebnf",
    "ion7.grammar.from.dynamic",
    "ion7.grammar.from.types",
    "ion7.grammar.from.json",
    "ion7.grammar.from.json.converter",
    "ion7.grammar.runtime.context",
    "ion7.grammar.runtime.backtrack",
    "ion7.grammar.runtime.dccd",
    "ion7.grammar.dev.debug",
    "ion7.grammar.dev.fuzz",
}

for _, mod in ipairs(sub_modules) do
    T.test("require '" .. mod .. "'", function()
        T.no_error(function() require(mod) end)
    end)
end

T.suite("ion7.grammar — public constructors are functions")

T.test("Grammar.from_regex / from_abnf / from_ebnf / from_auto", function()
    local Grammar = require "ion7.grammar"
    T.is_type(Grammar.from_regex, "function")
    T.is_type(Grammar.from_abnf,  "function")
    T.is_type(Grammar.from_ebnf,  "function")
    T.is_type(Grammar.from_auto,  "function")
end)

T.test("Grammar.from_json_schema / from_json_schema_native / from_type", function()
    local Grammar = require "ion7.grammar"
    T.is_type(Grammar.from_json_schema,        "function")
    T.is_type(Grammar.from_json_schema_native, "function")
    T.is_type(Grammar.from_type,               "function")
end)

T.test("Grammar.builder / raw / context / backtrack / dccd", function()
    local Grammar = require "ion7.grammar"
    T.is_type(Grammar.builder,   "function")
    T.is_type(Grammar.raw,       "function")
    T.is_type(Grammar.context,   "function")
    T.is_type(Grammar.backtrack, "function")
    T.is_type(Grammar.dccd,      "function")
end)

local ok = T.summary()
os.exit(ok and 0 or 1)
