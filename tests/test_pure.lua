#!/usr/bin/env luajit
--- ion7-grammar pure Lua test runner — no model required.
---
--- Loads all spec files and prints a unified summary.
--- Run: luajit tests/test_pure.lua
---
--- Individual suites can also be run standalone, e.g.:
---   luajit tests/spec/test_ast.lua
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

dofile("tests/spec/test_ast.lua")
dofile("tests/spec/test_from.lua")
dofile("tests/spec/test_grammar.lua")
dofile("tests/spec/test_runtime.lua")
dofile("tests/spec/test_dev.lua")

local T  = require "tests.framework"
local ok = T.summary()
os.exit(ok and 0 or 1)
