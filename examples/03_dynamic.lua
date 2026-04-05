--- examples/03_dynamic.lua
--- ion7-grammar - Input-dependent grammars and GrammarContext.
---
--- Standard grammars are static. Dynamic grammars are built from runtime
--- data - the model becomes physically incapable of generating values that
--- don't exist in your dataset.
---
--- This example shows:
---   - Grammar.from_enum with runtime values
---   - GrammarContext: stateful grammar that evolves across conversation turns
---   - Grammar.from_tools with a real tool registry
---   - Snapshot/restore for branching grammar state
---
--- Run:
---   luajit examples/03_dynamic.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grammar = require "ion7.grammar"

local function section(title)
    io.write("\n── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

io.write("══ ion7-grammar dynamic grammars ════════════════════════════\n")

-- ── 1. Runtime whitelist from a database schema ───────────────────────────────
section("from_enum: runtime database schema")

--- Simulate a database schema discovered at runtime.
--- In production: replace with actual db:get_tables(), db:get_columns() calls.
local db_schema = {
    tables = {
        users     = { "id", "username", "email", "created_at", "role" },
        orders    = { "id", "user_id", "total", "status", "placed_at" },
        products  = { "id", "name", "price", "category", "stock" },
    }
}

--- Build grammar that only allows real table names.
local all_tables  = {}
local all_columns = {}
for tname, cols in pairs(db_schema.tables) do
    all_tables[#all_tables + 1] = tname
    for _, c in ipairs(cols) do all_columns[#all_columns + 1] = c end
end

local table_grammar  = Grammar.from_enum("root", all_tables)
local column_grammar = Grammar.from_enum("root", all_columns)

io.write("  table names (fuzz): ")
io.write(table.concat(Grammar.fuzz(table_grammar, { count = 4, seed = 1 }), " | ") .. "\n")

io.write("  column names (fuzz): ")
io.write(table.concat(Grammar.fuzz(column_grammar, { count = 5, seed = 2 }), " | ") .. "\n")

-- ── 2. Tool registry ──────────────────────────────────────────────────────────
section("from_tools: tool-call grammar from registry")

--- A real tool registry. Grammar.from_tools() generates the full JSON grammar
--- that covers all tool names and their argument schemas.
local tools = {
    {
        name = "search-web",
        schema = {
            type = "object",
            properties = {
                query     = { type = "string" },
                max_results = { type = "integer" },
            },
            required = { "query" },
        },
    },
    {
        name = "read-file",
        schema = {
            type = "object",
            properties = {
                path     = { type = "string" },
                encoding = { enum = { "utf8", "binary" } },
            },
            required = { "path" },
        },
    },
    {
        name = "write-file",
        schema = {
            type = "object",
            properties = {
                path    = { type = "string" },
                content = { type = "string" },
            },
            required = { "path", "content" },
        },
    },
    {
        name = "run-sql",
        schema = {
            type = "object",
            properties = {
                query   = { type = "string" },
                db      = { enum = { "main", "analytics", "archive" } },
            },
            required = { "query" },
        },
    },
}

local tool_grammar = Grammar.from_tools(tools)
io.write("  tool grammar rules: " .. #tool_grammar:rules() .. "\n")
io.write("  tool grammar size:  " .. #tool_grammar:to_gbnf() .. " bytes\n")
io.write("  (constrains model to only call registered tool names)\n")

-- ── 3. GrammarContext - stateful grammar ──────────────────────────────────────
section("GrammarContext: grammar that grows across turns")

--- Simulates an agentic conversation where the grammar expands as the agent
--- discovers more about the environment.
local gc = Grammar.context()

--- Turn 1: agent only knows basic operations.
gc:learn_enum("operation", { "list", "describe", "help" })
local turn1_grammar = gc:current()
io.write("  Turn 1 - " .. gc:stats().n_enums .. " enums, rules: ")
io.write(#turn1_grammar:rules() .. "\n")

io.write("  Turn 1 samples: ")
io.write(table.concat(Grammar.fuzz(turn1_grammar, { count = 4, seed = 1, root = "operation" }), " | ") .. "\n")

--- Turn 2: agent discovers available tables.
gc:learn_table("users", { "id", "name", "email" })
gc:learn_table("orders", { "id", "user_id", "total" })
local turn2_grammar = gc:current()
io.write("  Turn 2 - " .. gc:stats().n_enums .. " enums, " ..
         gc:stats().n_tables .. " tables, rules: " .. #turn2_grammar:rules() .. "\n")

--- Turn 3: agent registers tools.
gc:learn_tool("search", { type = "object",
    properties = { query = { type = "string" } }, required = { "query" } })
gc:learn_tool("export", { type = "object",
    properties = { format = { enum = { "csv", "json", "parquet" } } }, required = { "format" } })
local turn3_grammar = gc:current()
io.write("  Turn 3 - " .. gc:stats().n_tools .. " tools, rules: " .. #turn3_grammar:rules() .. "\n")

-- ── 4. Snapshot / restore for branching ───────────────────────────────────────
section("GrammarContext: snapshot / restore")

--- Save state before a risky operation.
local snapshot = gc:snapshot()
io.write("  State before branch: " .. gc:stats().n_enums .. " enums\n")

--- Add a temporary grammar state (e.g., user-specific context).
gc:learn_enum("user-role", { "admin", "editor", "viewer" })
gc:learn_enum("permission", { "read", "write", "delete", "grant" })
io.write("  State in branch:     " .. gc:stats().n_enums .. " enums\n")

--- Restore to pre-branch state (e.g., conversation session ended).
gc:restore(snapshot)
io.write("  State after restore: " .. gc:stats().n_enums .. " enums\n")

-- ── 5. Forget and update ──────────────────────────────────────────────────────
section("GrammarContext: forget and update")

local gc2 = Grammar.context()
gc2:learn_enum("status", { "pending", "active", "suspended" })
io.write("  Before forget: " .. gc2:stats().n_enums .. " enum(s)\n")

--- Remove stale knowledge.
gc2:forget("status")
io.write("  After forget:  " .. gc2:stats().n_enums .. " enum(s)\n")

--- Add fresh data.
gc2:learn_enum("status", { "draft", "published", "archived" })
io.write("  After update:  " .. gc2:stats().n_enums .. " enum(s)\n")

local updated = gc2:current()
io.write("  Updated samples: ")
local s2 = Grammar.fuzz(updated, { count = 3, seed = 3, root = "status" })
io.write(table.concat(s2, " | ") .. "\n")

-- ── 6. from_enum + except_values ─────────────────────────────────────────────
section("except_values: whitelist complement")

--- All HTTP methods except DELETE.
local safe_methods = Grammar.except_values(
    { "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    { "DELETE" },
    "root"
)
io.write("  Safe HTTP methods (fuzz): ")
io.write(table.concat(Grammar.fuzz(safe_methods, { count = 5, seed = 5 }), " | ") .. "\n")

--- All log levels except debug (too verbose for production).
local prod_levels = Grammar.except_values(
    { "debug", "info", "warn", "error", "fatal" },
    { "debug" },
    "root"
)
io.write("  Production log levels: ")
io.write(table.concat(Grammar.fuzz(prod_levels, { count = 4, seed = 6 }), " | ") .. "\n")

io.write("\n══ done ═══════════════════════════════════════════════════════\n")
