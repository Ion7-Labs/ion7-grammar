package = "ion7-grammar"
version = "0.1-0"
source  = { url = "git+https://github.com/Ion7-Labs/ion7-grammar.git", tag = "v0.1.0" }
description = {
    summary  = "GBNF grammar engine for LuaJIT",
    detailed = [[
        Pure Lua grammar engine for llama.cpp constrained decoding.
        JSON Schema, Regex, Lua type annotations, input-dependent grammars,
        composition, fuzzing, stateful context, DCCD (Feb 2026), debugging,
        KV-cache backtracking (IterGen/CRANE). Zero C dependencies.
    ]],
    homepage = "https://github.com/Ion7-Labs/ion7-grammar",
    license  = "MIT-or-later",
}
dependencies = { "lua >= 5.1" }
build = {
    type = "builtin",
    modules = {
        ["ion7.grammar"]           = "src/ion7/grammar/init.lua",
        ["ion7.grammar.ast"]       = "src/ion7/grammar/ast.lua",
        ["ion7.grammar.compiler"]  = "src/ion7/grammar/compiler.lua",
        ["ion7.grammar.builder"]   = "src/ion7/grammar/builder.lua",
        ["ion7.grammar.regex"]     = "src/ion7/grammar/regex.lua",
        ["ion7.grammar.json"]      = "src/ion7/grammar/json.lua",
        ["ion7.grammar.dynamic"]   = "src/ion7/grammar/dynamic.lua",
        ["ion7.grammar.compose"]   = "src/ion7/grammar/compose.lua",
        ["ion7.grammar.types"]     = "src/ion7/grammar/types.lua",
        ["ion7.grammar.backtrack"] = "src/ion7/grammar/backtrack.lua",
        ["ion7.grammar.fuzz"]      = "src/ion7/grammar/fuzz.lua",
        ["ion7.grammar.context"]   = "src/ion7/grammar/context.lua",
        ["ion7.grammar.dccd"]      = "src/ion7/grammar/dccd.lua",
        ["ion7.grammar.debug"]     = "src/ion7/grammar/debug.lua",
        ["ion7.grammar.except"]    = "src/ion7/grammar/except.lua",
    },
}
