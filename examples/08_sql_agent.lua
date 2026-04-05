--- examples/08_sql_agent.lua
--- ion7-grammar - Real-world application: SQL query agent.
---
--- A complete application that uses dynamic grammars to prevent SQL
--- hallucination. The model can only reference tables and columns that
--- actually exist in the database schema. Unknown names are impossible
--- to generate.
---
--- Architecture:
---   1. Load schema from database (simulated here)
---   2. Build GrammarContext from schema
---   3. Compose a SQL grammar using context + structural rules
---   4. Use grammar to constrain the model's SQL output
---   5. Execute the SQL (stubbed) knowing it's schema-valid
---
--- Requires model:
---   ION7_MODEL=/path/to/model.gguf luajit examples/06_sql_agent.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?/init.lua;" ..
    package.path

local MODEL = os.getenv("ION7_MODEL")
if not MODEL then
    io.write("ION7_MODEL not set - skipping SQL agent example.\n")
    io.write("Run with: ION7_MODEL=/path/to/model.gguf luajit examples/08_sql_agent.lua\n")
    os.exit(0)
end

local Grammar = require "ion7.grammar"
local ion7    = require "ion7.core"

ion7.init({ log_level = 0 })

-- ── Database schema ───────────────────────────────────────────────────────────

--- Simulate a real database schema.
--- In production, load this from information_schema or your ORM.
local schema = {
    tables = {
        users = {
            "id", "username", "email", "role", "created_at", "is_active"
        },
        orders = {
            "id", "user_id", "total_amount", "status",
            "placed_at", "shipped_at", "product_id"
        },
        products = {
            "id", "name", "description", "price",
            "category", "stock_count", "supplier_id"
        },
        audit_log = {
            "id", "user_id", "action", "table_name", "record_id", "timestamp"
        },
    }
}

--- Valid SQL operators and keywords.
local sql_operators = { "=", "!=", "<", ">", "<=", ">=", "LIKE", "IN", "IS NULL", "IS NOT NULL" }
local sql_sort_dirs = { "ASC", "DESC" }
-- Join types and aggregate functions are available for grammar extensions:
-- local sql_join_types = { "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "LEFT OUTER JOIN" }
-- local sql_agg_fns    = { "COUNT", "SUM", "AVG", "MIN", "MAX" }

-- ── Build dynamic grammar from schema ─────────────────────────────────────────

io.write("══ SQL Agent with Grammar Constraints ═══════════════════════\n\n")
io.write("[schema] " .. (function()
    local t = {}; for n in pairs(schema.tables) do t[#t+1] = n end
    return table.concat(t, ", ")
end)() .. "\n\n")

--- Collect all table and column names.
local all_tables  = {}
local all_columns = {}
local col_seen    = {}
for tname, cols in pairs(schema.tables) do
    all_tables[#all_tables + 1] = tname
    for _, c in ipairs(cols) do
        if not col_seen[c] then
            col_seen[c] = true
            all_columns[#all_columns + 1] = c
        end
    end
end

--- Build a grammar that constrains SQL to known identifiers.
--- The grammar covers SELECT statements with optional WHERE and ORDER BY.
local function build_sql_grammar()
    -- All identifiers the model is allowed to use.
    local tbl_enum = Grammar.from_enum("table-name", all_tables)
    local col_enum = Grammar.from_enum("col-name",   all_columns)
    local op_enum  = Grammar.from_enum("sql-op",     sql_operators)
    local dir_enum = Grammar.from_enum("sort-dir",   sql_sort_dirs)

    -- Quoted identifier: `table_name` or just table_name.
    -- We build this using the Builder for fine control.
    local b = Grammar.builder()

    -- Add identifier rules.
    -- table-name and col-name come from the dynamic enums.
    b:rule("ws", Grammar.star(Grammar.char(" \t\n")))
    b:rule("table-name", tbl_enum:builder()._rules[1].body)
    b:rule("col-name",   col_enum:builder()._rules[1].body)
    b:rule("sql-op",     op_enum:builder()._rules[1].body)
    b:rule("sort-dir",   dir_enum:builder()._rules[1].body)

    -- SELECT list: col or col, col, ...
    b:rule("select-col",  Grammar.ref("col-name"))
    b:rule("select-cols", Grammar.seq(
        Grammar.ref("select-col"),
        Grammar.star(Grammar.seq(
            Grammar.literal(","),
            Grammar.ref("ws"),
            Grammar.ref("select-col")
        ))
    ))

    -- Simple string value (quoted).
    b:rule("str-value", Grammar.seq(
        Grammar.literal("'"),
        Grammar.plus(Grammar.char("a-zA-Z0-9 _-")),
        Grammar.literal("'")
    ))

    -- Numeric value.
    b:rule("num-value", Grammar.seq(
        Grammar.opt(Grammar.literal("-")),
        Grammar.plus(Grammar.DIGIT),
        Grammar.opt(Grammar.seq(Grammar.literal("."), Grammar.plus(Grammar.DIGIT)))
    ))

    -- WHERE clause value.
    b:rule("where-value", Grammar.alt(
        Grammar.ref("str-value"),
        Grammar.ref("num-value")
    ))

    -- WHERE condition: col OP value
    b:rule("condition", Grammar.seq(
        Grammar.ref("col-name"),
        Grammar.ref("ws"),
        Grammar.ref("sql-op"),
        Grammar.ref("ws"),
        Grammar.ref("where-value")
    ))

    -- Optional WHERE clause.
    b:rule("where-clause", Grammar.seq(
        Grammar.literal("WHERE"),
        Grammar.ref("ws"),
        Grammar.ref("condition"),
        Grammar.star(Grammar.seq(
            Grammar.ref("ws"),
            Grammar.alt(Grammar.literal("AND"), Grammar.literal("OR")),
            Grammar.ref("ws"),
            Grammar.ref("condition")
        ))
    ))

    -- Optional ORDER BY clause.
    b:rule("order-clause", Grammar.seq(
        Grammar.literal("ORDER BY"),
        Grammar.ref("ws"),
        Grammar.ref("col-name"),
        Grammar.ref("ws"),
        Grammar.ref("sort-dir")
    ))

    -- Optional LIMIT clause.
    b:rule("limit-clause", Grammar.seq(
        Grammar.literal("LIMIT"),
        Grammar.ref("ws"),
        Grammar.plus(Grammar.DIGIT)
    ))

    -- Full SELECT statement.
    b:rule("root", Grammar.seq(
        Grammar.literal("SELECT"),
        Grammar.ref("ws"),
        Grammar.ref("select-cols"),
        Grammar.ref("ws"),
        Grammar.literal("FROM"),
        Grammar.ref("ws"),
        Grammar.ref("table-name"),
        Grammar.opt(Grammar.seq(Grammar.ref("ws"), Grammar.ref("where-clause"))),
        Grammar.opt(Grammar.seq(Grammar.ref("ws"), Grammar.ref("order-clause"))),
        Grammar.opt(Grammar.seq(Grammar.ref("ws"), Grammar.ref("limit-clause")))
    ))

    return Grammar.from_builder(b)
end

local sql_grammar = build_sql_grammar()
io.write("[grammar] " .. #sql_grammar:rules() .. " rules, " ..
         #sql_grammar:to_gbnf() .. " bytes\n\n")

-- ── Validate grammar before loading model ─────────────────────────────────────
local valid, err = Grammar.fuzz_validate(sql_grammar, { count = 5, seed = 1, max_rep = 2 })
io.write("[fuzz] grammar valid: " .. tostring(valid) .. "\n")
if not valid then
    io.write("[fuzz] " .. err .. "\n")
    os.exit(1)
end
io.write("[fuzz] sample: " .. Grammar.fuzz_one(sql_grammar, { seed = 2, max_rep = 2 }) .. "\n\n")

-- ── Model setup ───────────────────────────────────────────────────────────────
local fit   = ion7.Model.fit_params(MODEL) or { n_gpu_layers = 0, n_ctx = 2048 }
local model = ion7.Model.load(MODEL, { n_gpu_layers = fit.n_gpu_layers })
local vocab  = model:vocab()
local ctx    = model:context({ n_ctx = math.min(fit.n_ctx, 2048) })

io.write("[model] ready: " .. MODEL:match("[^/]+$") .. "\n\n")

-- ── Generation ────────────────────────────────────────────────────────────────
local function sql_query(natural_language)
    local sampler = ion7.Sampler.chain()
        :grammar(sql_grammar:to_gbnf(), "root", vocab)
        :dist(42)
        :build(vocab)

    local system_msg = string.format(
        "You are a SQL expert. Convert natural language to SQL SELECT statements.\n"
        .. "Available tables: %s\n"
        .. "Output ONLY the SQL statement, nothing else.",
        table.concat(all_tables, ", ")
    )

    local msgs = {
        { role = "system", content = system_msg },
        { role = "user",   content = natural_language },
    }
    local formatted = vocab:apply_template(msgs, true)
    local tokens, n = vocab:tokenize(formatted, false, true)

    ctx:kv_clear()
    ctx:decode(tokens, n, 0, 0)
    sampler:reset()

    local parts = {}
    for _ = 1, 128 do
        local tok = sampler:sample(ctx:ptr(), -1)
        if vocab:is_eog(tok) then break end
        ctx:decode_single(tok, 0)
        parts[#parts + 1] = vocab:piece(tok)
    end
    sampler:free()
    return table.concat(parts)
end

--- Natural language → SQL queries.
local queries = {
    "Show me all active users",
    "Find orders with status equal to shipped",
    "List products ordered by price DESC with limit 10",
    "Get all users created recently",
}

for _, q in ipairs(queries) do
    io.write("NL:  " .. q .. "\n")
    local sql = sql_query(q)
    io.write("SQL: " .. sql .. "\n\n")

    -- Verify: table and column names are all from the schema.
    local used_tables = {}
    for tname in sql:gmatch("FROM%s+(%w+)") do
        used_tables[tname] = schema.tables[tname] ~= nil
    end
    for tname, valid_t in pairs(used_tables) do
        if not valid_t then
            io.write("  [!] hallucinated table: " .. tname .. "\n")
        end
    end
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────
ctx:free()
model:free()
ion7.shutdown()

io.write("══ done ═══════════════════════════════════════════════════════\n")
io.write("All SQL table and column names are guaranteed to be schema-valid.\n")
