#!/usr/bin/env luajit
--- ion7-grammar model tests - requires a real GGUF model.
---
--- Usage:
---   ION7_MODEL=/path/to/model.gguf luajit tests/test_model.lua
---   ION7_CORE=/path/to/ion7-core    (optional, default: ../ion7-core)

package.path = "./src/?.lua;./src/?/init.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?/init.lua;" ..
    package.path

local MODEL = os.getenv("ION7_MODEL")
if not MODEL then
    io.stderr:write("Usage: ION7_MODEL=/path/to/model.gguf luajit tests/test_model.lua\n")
    os.exit(1)
end

local ok_count, fail_count = 0, 0
local function ok(cond, msg, detail)
    if cond then
        ok_count = ok_count + 1
        io.write("  [OK] " .. msg .. "\n")
    else
        fail_count = fail_count + 1
        io.write("  [FAIL] " .. msg)
        if detail then io.write(" - " .. tostring(detail)) end
        io.write("\n")
    end
end

local Grammar = require "ion7.grammar"
local ion7    = require "ion7.core"
ion7.init({ log_level = 0 })

io.write("\n══ ion7-grammar model tests ══════════════════════════════════\n")

local fit   = ion7.Model.fit_params(MODEL) or { n_gpu_layers = 0, n_ctx = 2048 }
local model = ion7.Model.load(MODEL, { n_gpu_layers = fit.n_gpu_layers })
local vocab  = model:vocab()
local ctx    = model:context({ n_ctx = math.min(fit.n_ctx, 2048) })
io.write(string.format("[setup] ready - %s\n\n", MODEL:match("[^/]+$")))

-- ── Generate helper ────────────────────────────────────────────────────────────
-- NOTE: pass vocab TABLE (not vocab._ptr) to :grammar().
--       llama_sampler_sample() on a chain already calls accept internally -
--       do NOT call sampler:accept() separately (double-accept crashes grammar state).
local function generate(gbnf, root, prompt, max_tokens)
    local sampler = ion7.Sampler.chain()
        :grammar(gbnf, root or "root", vocab)
        :dist(42)
        :build(vocab)

    local msgs      = { { role = "user", content = prompt } }
    local formatted = vocab:apply_template(msgs, true)
    local tokens, n = vocab:tokenize(formatted, false, true)

    ctx:kv_clear()
    ctx:decode(tokens, n, 0, 0)
    sampler:reset()

    local parts = {}
    for _ = 1, (max_tokens or 64) do
        local tok = sampler:sample(ctx:ptr(), -1)
        if vocab:is_eog(tok) then break end
        ctx:decode_single(tok, 0)
        parts[#parts + 1] = vocab:piece(tok)
    end
    sampler:free()
    return table.concat(parts)
end

-- ── 1. Enum ────────────────────────────────────────────────────────────────────
io.write("── 1. Enum - Grammar.from_enum ─────────────────────────────────\n")
local g1 = Grammar.from_enum("root", { "positive", "negative", "neutral" })
local r1 = generate(g1:to_gbnf(), "root",
    "Is 'I love this!' positive, negative, or neutral? One word:", 8)
io.write("  output: '" .. r1 .. "'\n")
local valid_sent = { positive=true, negative=true, neutral=true }
ok(valid_sent[r1], "from_enum: constrained to valid values", r1)

-- ── 2. JSON Schema ─────────────────────────────────────────────────────────────
io.write("\n── 2. JSON Schema ───────────────────────────────────────────────\n")
local g2 = Grammar.from_json_schema({
    type = "object",
    properties = {
        name  = { type = "string" },
        score = { type = "integer" },
    },
    required = { "name", "score" },
    additionalProperties = false,
})
local r2 = generate(g2:to_gbnf(), "root",
    'Output JSON with name="Alice" and score=42. JSON only:', 64)
io.write("  output: " .. r2 .. "\n")
ok(r2:find("{") and r2:find("}"), "JSON schema: valid object", r2)

-- ── 3. Type annotation ─────────────────────────────────────────────────────────
io.write("\n── 3. Type annotation - from_type ───────────────────────────────\n")
local g3 = Grammar.from_type({ status = "string", count = "integer" })
local r3 = generate(g3:to_gbnf(), "root",
    'Output JSON with status="ok" and count=3. JSON only:', 48)
io.write("  output: " .. r3 .. "\n")
ok(r3:find("{"), "from_type: output looks like JSON", r3)

-- ── 4. Regex ───────────────────────────────────────────────────────────────────
io.write("\n── 4. Regex - YYYY-MM-DD ────────────────────────────────────────\n")
local g4 = Grammar.from_regex("[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]")
local r4 = generate(g4:to_gbnf(), "root", "Output today's date as YYYY-MM-DD:", 16)
io.write("  output: '" .. r4 .. "'\n")
ok(#r4 == 10, "regex: exactly 10 chars", tostring(#r4))
ok(r4:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil, "regex: YYYY-MM-DD format", r4)

-- ── 5. HTTP method whitelist ───────────────────────────────────────────────────
io.write("\n── 5. Dynamic enum - HTTP methods ──────────────────────────────\n")
local g5 = Grammar.from_enum("root", { "GET", "POST", "PUT", "DELETE", "PATCH" })
local r5 = generate(g5:to_gbnf(), "root",
    "What HTTP method retrieves data without side effects? One word:", 8)
io.write("  output: '" .. r5 .. "'\n")
local valid_methods = { GET=true, POST=true, PUT=true, DELETE=true, PATCH=true }
ok(valid_methods[r5] ~= nil, "dynamic enum: valid HTTP method", r5)

-- ── 6. Fuzz validation ─────────────────────────────────────────────────────────
io.write("\n── 6. Fuzz - zero-LLM pre-validation ───────────────────────────\n")
local g6      = Grammar.from_enum("root", { "red", "green", "blue" })
local samples = Grammar.fuzz(g6, { count = 6, seed = 42 })
local colors  = { red=true, green=true, blue=true }
local all_ok  = true
for _, s in ipairs(samples) do if not colors[s] then all_ok = false end end
ok(all_ok,    "fuzz: all samples are valid enum values")
ok(#samples == 6, "fuzz: generates correct count")

-- ── 7. from_tools ─────────────────────────────────────────────────────────────
io.write("\n── 7. Tool-call grammar - from_tools ───────────────────────────\n")
local g7 = Grammar.from_tools({
    { name = "search", schema = { type = "object",
        properties = { query = { type = "string" } },
        required = { "query" } } },
    { name = "calculate", schema = { type = "object",
        properties = { expr = { type = "string" } },
        required = { "expr" } } },
})
local r7 = generate(g7:to_gbnf(), "root",
    'Output a tool call JSON to search for "lua". Use {"name":"search","arguments":{"query":"..."}} format:', 64)
io.write("  output: " .. r7 .. "\n")
ok(r7:find("search") or r7:find("calculate"), "from_tools: valid tool name present", r7)
ok(r7:find("{") and r7:find("}"), "from_tools: output is JSON", r7)

-- ── 8. Compose.union ──────────────────────────────────────────────────────────
io.write("\n── 8. Compose.union ─────────────────────────────────────────────\n")
local ga = Grammar.from_enum("root", { "yes", "true" })
local gb = Grammar.from_enum("root", { "no", "false" })
local g8 = Grammar.union(ga, gb)
local r8 = generate(g8:to_gbnf(), "root", "Is 2+2=4? Answer yes, no, true, or false:", 8)
io.write("  output: '" .. r8 .. "'\n")
local valid8 = { yes=true, no=true, ["true"]=true, ["false"]=true }
ok(valid8[r8] ~= nil, "union: output is one of the combined values", r8)

-- ── 9. GrammarContext ─────────────────────────────────────────────────────────
io.write("\n── 9. GrammarContext - stateful grammar ─────────────────────────\n")
local gc = Grammar.context()
gc:learn_enum("color", { "red", "green", "blue" })
local g9 = gc:current()
local r9 = generate(g9:to_gbnf("color"), "color",
    "What color is the sky at night? red, green, or blue:", 6)
io.write("  output: '" .. r9 .. "'\n")
local valid9 = { red=true, green=true, blue=true }
ok(valid9[r9] ~= nil, "context: current() grammar constrains output", r9)
-- Extend context and verify new grammar includes new values
gc:learn_enum("size", { "small", "large" })
ok(gc:stats().n_enums == 2, "context: learned 2 enums")

-- ── Cleanup ────────────────────────────────────────────────────────────────────
ctx:free()
model:free()
ion7.shutdown()

io.write(string.format(
    "\n────────────────────────────────────────────────────────────\n" ..
    "  %d/%d passed\n", ok_count, ok_count + fail_count))
if fail_count > 0 then os.exit(1) end
