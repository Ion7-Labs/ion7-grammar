#!/usr/bin/env luajit
--- 06_backtrack.lua - KV cache backtracking (IterGen / CRANE pattern).
---
--- Standard constrained decoding generates left-to-right with no recourse.
--- If the model produces "SELECT * FROM fake_table", there is no way to
--- go back and fix "fake_table" without restarting the whole generation.
---
--- Backtracking solves this:
---   1. Save a KV snapshot just before a grammar symbol (checkpoint)
---   2. Generate until that symbol is complete
---   3. Validate the output semantically (e.g. is the table name real?)
---   4. If invalid: restore KV to the snapshot and resample
---   5. Repeat until valid or max_retries exhausted
---
--- This is NOT a retry of the full generation - only the bad fragment is
--- resampled. The rest of the context (including what came before) is intact.
---
--- Inspired by IterGen (ICLR 2025) and CRANE (ICML 2025).
--- ion7-grammar implements this natively via ion7-core KV snapshots.
---
--- Run:
---   ION7_MODEL=/path/to/model.gguf luajit examples/06_backtrack.lua
---   ION7_CORE=/path/to/ion7-core   (optional, default: ../ion7-core)

package.path = "./src/?.lua;./src/?/init.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?/init.lua;" ..
    package.path

local MODEL = os.getenv("ION7_MODEL")
if not MODEL then
    io.write("ION7_MODEL not set - skipping backtrack example.\n")
    io.write("Run with: ION7_MODEL=/path/to/model.gguf luajit examples/06_backtrack.lua\n")
    os.exit(0)
end

local Grammar = require "ion7.grammar"
local ion7    = require "ion7.core"

ion7.init({ log_level = 0 })

-- ── Setup ─────────────────────────────────────────────────────────────────────

local fit   = ion7.Model.fit_params(MODEL) or { n_gpu_layers = 0, n_ctx = 4096 }
local model = ion7.Model.load(MODEL, { n_gpu_layers = fit.n_gpu_layers })
local vocab  = model:vocab()
-- Need room for prompt + draft + constrained tokens
local ctx    = model:context({ n_ctx = math.min(fit.n_ctx, 4096) })

io.write("══ ion7-grammar backtracking ════════════════════════════════\n")
io.write("[model] " .. MODEL:match("[^/]+$") .. "\n\n")

-- ── Simulated database schema ─────────────────────────────────────────────────
-- In production: replace with actual db:get_tables() / db:get_columns() calls.

local SCHEMA = {
    users    = { "id", "username", "email", "role", "created-at" },
    orders   = { "id", "user-id", "total", "status", "placed-at" },
    products = { "id", "name", "price", "category", "stock" },
}

local function table_exists(name)
    return SCHEMA[name] ~= nil
end

local function column_exists(table_name, col)
    if not SCHEMA[table_name] then return false end
    for _, c in ipairs(SCHEMA[table_name]) do
        if c == col then return true end
    end
    return false
end

-- ── Build grammars ────────────────────────────────────────────────────────────

-- A grammar that produces valid SQL SELECT structure.
-- The table name and column name are generated freely - validation enforces
-- that only real schema values are accepted.
local table_names = {}
for t in pairs(SCHEMA) do table_names[#table_names + 1] = t end

local sql_grammar = Grammar.from_enum("root", table_names)

-- Sampler: grammar-constrained so only valid table names are possible tokens.
local function make_sampler(gbnf)
    local s = ion7.Sampler.chain()
        :grammar(gbnf, "root", vocab)
        :dist(math.random(1, 9999))
        :build(vocab)
    return s
end

-- ── Prefill the prompt ────────────────────────────────────────────────────────

local function prefill(messages)
    local formatted = vocab:apply_template(messages, true)
    local tokens, n = vocab:tokenize(formatted, false, true)
    ctx:kv_clear()
    ctx:decode(tokens, n, 0, 0)
end

-- ── Example 1: checkpoint + constrain ────────────────────────────────────────
-- Generate a table name and reject it if it is not in the schema.
-- Without backtracking, a grammar-only approach would generate the first
-- valid token sequence; with constrain() we enforce semantic correctness.

io.write("── 1. Checkpoint + constrain ───────────────────────────────────\n")

prefill({ { role = "user", content =
    "Write a SQL SELECT query. Output the table name only. Use one of: "
    .. table.concat(table_names, ", ")
}})

local sampler = make_sampler(sql_grammar:to_gbnf())
local bt = Grammar.backtrack(ctx, vocab, sampler, {
    max_tokens  = 20,
    max_retries = 8,
})

bt:checkpoint("table-name")
bt:forward(function(_, text)
    -- stop when we have a complete word (space or EOG will break the loop)
    return #text >= 3 and text:find("[^a-z]", -1)
end, 10)

local accepted = bt:constrain("table-name", function(text)
    local name = text:match("([a-z]+)%s*$") or text:match("^([a-z]+)")
    return name and table_exists(name)
end)

io.write(string.format("  table name generated: %q\n", bt:text()))
io.write(string.format("  constraint satisfied: %s\n\n", tostring(accepted)))

sampler:free()

-- ── Example 2: bt:run() - multi-step constrained generation ──────────────────
-- High-level API: checkpoint + forward + constrain per step.
-- Generates "table:column" and validates both independently.

io.write("── 2. bt:run() - multi-step ────────────────────────────────────\n")

-- Grammar: "table:column"
local all_columns = {}
for _, cols in pairs(SCHEMA) do
    for _, c in ipairs(cols) do
        all_columns[c] = true
    end
end
local col_list = {}
for c in pairs(all_columns) do col_list[#col_list + 1] = c end

local table_g  = Grammar.from_enum("root", table_names)
local column_g = Grammar.from_enum("root", col_list)
local pair_g   = table_g:then_(column_g, Grammar.literal(":"))

prefill({ { role = "user", content =
    "Pick a real database table and one of its columns. Format: table:column"
}})

local sampler2 = ion7.Sampler.chain()
    :grammar(pair_g:to_gbnf(), "root", vocab)
    :dist(math.random(1, 9999))
    :build(vocab)

local bt2 = Grammar.backtrack(ctx, vocab, sampler2, {
    max_tokens  = 30,
    max_retries = 6,
})

local text2, all_ok = bt2:run({
    {
        symbol     = "table",
        until_pred = function(p) return p:find(":") ~= nil end,
        max_tokens = 10,
        validator  = function(t)
            local name = t:match("^([a-z]+)")
            return name and table_exists(name)
        end,
    },
    {
        symbol     = "column",
        until_pred = nil,  -- generate to EOG or max
        max_tokens = 10,
        validator  = function(t)
            local tbl = t:match("^([a-z]+):")
            local col = t:match(":([a-z%-]+)")
            return tbl and col and column_exists(tbl, col)
        end,
    },
})

io.write(string.format("  result: %q\n", text2))
io.write(string.format("  all constraints satisfied: %s\n\n", tostring(all_ok)))

sampler2:free()

-- ── Example 3: bt:backward() - manual resample ───────────────────────────────
-- Lower-level API. Useful when you need fine control over what is resampled.

io.write("── 3. bt:backward() - manual resample ──────────────────────────\n")

local status_g = Grammar.from_enum("root", { "shipped", "pending", "delivered", "cancelled" })

prefill({ { role = "user", content =
    "An order that was recently dispatched. Status?"
}})

local sampler3 = ion7.Sampler.chain()
    :grammar(status_g:to_gbnf(), "root", vocab)
    :dist(math.random(1, 9999))
    :build(vocab)

local bt3 = Grammar.backtrack(ctx, vocab, sampler3, {
    max_tokens  = 10,
    max_retries = 5,
})

bt3:checkpoint("status")
bt3:forward(nil, 8)  -- generate to EOG or 8 tokens

local raw = bt3:text()
io.write(string.format("  first attempt: %q\n", raw))

-- If we got "pending", backtrack and resample until we get a dispatch state.
if raw:find("pending") or raw:find("cancelled") then
    local ok3 = bt3:backward("status", function(piece)
        return not piece:find("pending") and not piece:find("cancelled")
    end)
    io.write(string.format("  after backward: %q  (ok=%s)\n", bt3:text(), tostring(ok3)))
else
    io.write("  first attempt was already valid, no backtrack needed\n")
end

io.write("\n")
sampler3:free()

-- ── Cleanup ───────────────────────────────────────────────────────────────────

ctx:free()
model:free()
ion7.shutdown()

io.write("══ done ═══════════════════════════════════════════════════════\n")
