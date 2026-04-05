--- examples/05_with_model.lua
--- ion7-grammar - Full generation pipeline with ion7-core.
---
--- Shows the complete workflow: build grammar → validate with fuzz →
--- constrain the sampler → generate → verify output.
---
--- Also demonstrates:
---   - Multi-turn conversation with GrammarContext
---   - Switching grammars mid-conversation
---   - Using different grammar types for different tasks in the same session
---
--- Run:
---   ION7_MODEL=/path/to/model.gguf luajit examples/05_with_model.lua
---   ION7_CORE=/path/to/ion7-core   (optional, default: ../ion7-core)
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?/init.lua;" ..
    package.path

local MODEL = os.getenv("ION7_MODEL")
if not MODEL then
    io.write("ION7_MODEL not set - skipping model examples.\n")
    io.write("Run with: ION7_MODEL=/path/to/model.gguf luajit examples/05_with_model.lua\n")
    os.exit(0)
end

local Grammar = require "ion7.grammar"
local ion7    = require "ion7.core"

ion7.init({ log_level = 0 })

-- ── Setup ─────────────────────────────────────────────────────────────────────

local fit   = ion7.Model.fit_params(MODEL) or { n_gpu_layers = 0, n_ctx = 4096 }
local model = ion7.Model.load(MODEL, { n_gpu_layers = fit.n_gpu_layers })
local vocab  = model:vocab()
local ctx    = model:context({ n_ctx = math.min(fit.n_ctx, 4096) })

io.write("══ ion7-grammar with model ═══════════════════════════════════\n")
io.write("[model] " .. MODEL:match("[^/]+$") .. "\n\n")

-- ── Core generation function ──────────────────────────────────────────────────

--- Generate constrained text using a grammar.
---
--- @param  grammar   Grammar_obj  The grammar to enforce.
--- @param  messages  table        Chat messages: { { role, content }, ... }
--- @param  max_tok   number?      Max tokens to generate (default: 64).
--- @return string  Generated text (guaranteed to match grammar).
local function generate(grammar, messages, max_tok)
    -- Pre-validate grammar with fuzzer before touching the GPU.
    local ok, err = Grammar.fuzz_validate(grammar, { count = 10, seed = 1 })
    if not ok then
        error("[generate] grammar validation failed: " .. tostring(err))
    end

    local gbnf    = grammar:to_gbnf()
    local sampler = ion7.Sampler.chain()
        :grammar(gbnf, "root", vocab)  -- pass vocab TABLE, not vocab._ptr
        :dist(42)
        :build(vocab)

    local formatted = vocab:apply_template(messages, true)
    local tokens, n = vocab:tokenize(formatted, false, true)

    ctx:kv_clear()
    ctx:decode(tokens, n, 0, 0)
    sampler:reset()

    local parts = {}
    for _ = 1, (max_tok or 64) do
        -- NOTE: llama_sampler_sample() on a chain already calls accept().
        -- Never call sampler:accept() separately - it causes a double-accept crash.
        local tok = sampler:sample(ctx:ptr(), -1)
        if vocab:is_eog(tok) then break end
        ctx:decode_single(tok, 0)
        parts[#parts + 1] = vocab:piece(tok)
    end
    sampler:free()
    return table.concat(parts)
end

local function section(title)
    io.write("── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

local function ask(grammar, prompt, max_tok)
    local result = generate(grammar, { { role = "user", content = prompt } }, max_tok)
    io.write("  prompt:  " .. prompt:sub(1, 60) .. "\n")
    io.write("  output:  " .. result .. "\n\n")
    return result
end

-- ── 1. Classification ─────────────────────────────────────────────────────────
section("1. Text classification")

local sentiment = Grammar.from_enum("root", { "positive", "negative", "neutral" })

ask(sentiment, "Review: 'Absolutely love this product, works perfectly!'")
ask(sentiment, "Review: 'Broken on arrival, complete waste of money.'")
ask(sentiment, "Review: 'It does what it says, nothing more.'")

-- ── 2. Structured extraction ──────────────────────────────────────────────────
section("2. Structured data extraction")

local person_schema = Grammar.from_json_schema({
    type = "object",
    properties = {
        name  = { type = "string" },
        age   = { type = "integer" },
        city  = { type = "string" },
    },
    required = { "name", "age", "city" },
    additionalProperties = false,
})

local r = ask(person_schema,
    "Extract info: 'Alice, 34 years old, lives in Lyon.' Output JSON only.", 64)

-- Optional: parse the JSON if dkjson is available.
local ok_json, json_lib = pcall(require, "dkjson")
if not ok_json then ok_json, json_lib = pcall(require, "cjson") end
if ok_json then
    local parsed = json_lib.decode(r)
    if parsed then
        io.write("  parsed.name: " .. tostring(parsed.name) .. "\n")
        io.write("  parsed.age:  " .. tostring(parsed.age)  .. "\n\n")
    end
end

-- ── 3. Format enforcement ─────────────────────────────────────────────────────
section("3. Strict format enforcement")

--- ISO date: model cannot output anything but YYYY-MM-DD.
local date_grammar = Grammar.from_regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
ask(date_grammar, "What is the date for next New Year's Eve? YYYY-MM-DD format:", 12)

--- Semantic version: vX.Y.Z
local version = Grammar.from_regex("v[0-9]+\\.[0-9]+\\.[0-9]+")
ask(version, "What version should we release next after v2.3.1?", 10)

-- ── 4. Decision trees with union ─────────────────────────────────────────────
section("4. Multi-level decision with union")

--- Combine two enums: yes/no for quick answers, or a confidence level.
local quick = Grammar.from_enum("root", { "yes", "no" })
local detailed = Grammar.from_enum("root", { "definitely", "probably", "unlikely", "never" })
local decision = Grammar.union(quick, detailed)

ask(decision, "Will it rain tomorrow in Paris?", 8)
ask(decision, "Should I invest in cryptocurrency?", 8)

-- ── 5. Tool calling ───────────────────────────────────────────────────────────
section("5. Tool-call grammar")

local tool_grammar = Grammar.from_tools({
    {
        name = "search-web",
        schema = { type = "object",
            properties = { query = { type = "string" } },
            required = { "query" } },
    },
    {
        name = "calculate",
        schema = { type = "object",
            properties = {
                expression = { type = "string" },
                precision  = { type = "integer" },
            },
            required = { "expression" } },
    },
    {
        name = "get-weather",
        schema = { type = "object",
            properties = { city = { type = "string" } },
            required = { "city" } },
    },
})

ask(tool_grammar,
    'Which tool should I call to find current news about AI? '
    .. 'Output a tool call JSON with {"name":"...","arguments":{...}}.',
    80)

-- ── 6. Multi-turn with GrammarContext ─────────────────────────────────────────
section("6. Multi-turn with evolving grammar")

--- The grammar grows as the conversation reveals more context.
local gc = Grammar.context()

--- Turn 1: User asks about status - we only know basic states.
gc:learn_enum("status", { "pending", "active", "closed" })
local g_turn1 = gc:current()
local r1 = generate(g_turn1, {
    { role = "user", content = "What is the status of order #123?" }
}, 8)
io.write("  Turn 1 status: " .. r1 .. "\n")

--- Turn 2: We discovered the order system has more states.
gc:learn_enum("status", { "pending", "active", "shipped", "delivered", "closed", "refunded" })
local g_turn2 = gc:current()
local r2 = generate(g_turn2, {
    { role = "user",      content = "What is the status of order #123?" },
    { role = "assistant", content = r1 },
    { role = "user",      content = "And what about order #456 - was it delivered?" },
}, 10)
io.write("  Turn 2 status: " .. r2 .. "\n\n")

-- ── Cleanup ───────────────────────────────────────────────────────────────────
ctx:free()
model:free()
ion7.shutdown()

io.write("══ done ═══════════════════════════════════════════════════════\n")
