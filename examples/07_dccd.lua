#!/usr/bin/env luajit
--- 07_dccd.lua - Draft-Conditioned Constrained Decoding (arXiv:2603.03305).
---
--- Standard grammar-constrained decoding has a "projection tax": at each
--- step the sampler masks all tokens not in the grammar, which distorts the
--- probability distribution. Over many steps this compounds - the model
--- follows the grammar but produces semantically poor content.
---
--- DCCD (Feb 2026) fixes this with two passes:
---
---   Pass 1 - Draft: generate text freely (no grammar). The model follows
---             its natural probability distribution and produces a plan.
---
---   Pass 2 - Constrain: restore KV to post-prompt, inject the draft tokens
---             into the KV cache, then run grammar-constrained generation on
---             the augmented context (prompt + draft + constrained_tokens_so_far).
---
--- The model now "knows" what it wanted to say (the draft) while being
--- physically forced to output grammar-valid tokens. The projection tax
--- is dramatically reduced.
---
--- Paper: arXiv:2603.03305v1 - results show +24pp on structured reasoning
---        and ~80% win rate vs standard constrained decoding on summarization.
---
--- Run:
---   ION7_MODEL=/path/to/model.gguf luajit examples/07_dccd.lua
---   ION7_CORE=/path/to/ion7-core   (optional, default: ../ion7-core)
---
--- Note: for thinking models (Qwen3, DeepSeek-R1) that produce <think>...</think>
--- blocks, set max_draft_tokens >= 512 so the think block can complete before
--- the constrained pass begins.

package.path = "./src/?.lua;./src/?/init.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?.lua;" ..
    (os.getenv("ION7_CORE") or "../ion7-core") .. "/src/?/init.lua;" ..
    package.path

local MODEL = os.getenv("ION7_MODEL")
if not MODEL then
    io.write("ION7_MODEL not set - skipping DCCD example.\n")
    io.write("Run with: ION7_MODEL=/path/to/model.gguf luajit examples/07_dccd.lua\n")
    os.exit(0)
end

local Grammar = require "ion7.grammar"
local ion7    = require "ion7.core"

ion7.init({ log_level = 0 })

-- ── Setup ─────────────────────────────────────────────────────────────────────

local fit   = ion7.Model.fit_params(MODEL) or { n_gpu_layers = 0, n_ctx = 4096 }
local model = ion7.Model.load(MODEL, { n_gpu_layers = fit.n_gpu_layers })
local vocab  = model:vocab()
-- Context must hold: prompt + max_draft + max_final tokens
local ctx    = model:context({ n_ctx = math.min(fit.n_ctx, 4096) })

io.write("══ ion7-grammar DCCD ═════════════════════════════════���═══════\n")
io.write("[model] " .. MODEL:match("[^/]+$") .. "\n\n")

-- ── Shared helpers ────────────────────────────────────────────────────────────

local function prefill(messages)
    local formatted = vocab:apply_template(messages, true)
    local tokens, n = vocab:tokenize(formatted, false, true)
    ctx:kv_clear()
    ctx:decode(tokens, n, 0, 0)
end

local function make_draft_sampler()
    -- Unconstrained: moderate temperature for variety in the draft
    return ion7.Sampler.chain()
        :top_k(40):top_p(0.9):temp(0.7):dist(math.random(1, 9999))
        :build(vocab)
end

local function make_constrained_sampler(gbnf)
    -- Grammar-constrained: low temperature for determinism within the grammar
    return ion7.Sampler.chain()
        :grammar(gbnf, "root", vocab)
        :temp(0.0):dist(42)
        :build(vocab)
end

-- ── Example 1: JSON extraction with DCCD ─────────────────────────────────────
-- Classic use case: extract structured data as valid JSON.
-- DCCD lets the model think freely first, then output the JSON.

io.write("── 1. JSON extraction ──────────────────────────────────────────\n")

local person_grammar = Grammar.from_type({
    name   = "string",
    age    = "integer",
    city   = "string",
})

local draft_s1       = make_draft_sampler()
local constrained_s1 = make_constrained_sampler(person_grammar:to_gbnf())

local dc1 = Grammar.dccd(ctx, vocab, {
    draft_sampler     = draft_s1,
    constrain_sampler = constrained_s1,
    max_draft_tokens  = 128,   -- draft: let model think
    max_final_tokens  = 128,   -- constrained: generate the JSON
    on_draft_token    = nil,   -- set to io.write to stream the draft
    on_final_token    = function(p) io.write(p); io.flush() end,
})

prefill({ { role = "user", content =
    "Extract the person's data as JSON:\n"
    .. "'Marie Curie was born in Warsaw in 1867. She lived in Paris and was 66 years old at death.'"
}})

io.write("  output: ")
local r1 = dc1:generate({ max_draft_tokens = 128, max_final_tokens = 128 })
io.write("\n")
if r1 then
    io.write(string.format("  draft: %q\n", r1.draft:sub(1, 80)))
    io.write(string.format("  tokens: draft=%d  constrained=%d\n\n",
        r1.n_draft_toks, r1.n_tokens))
end

draft_s1:free(); constrained_s1:free()

-- ── Example 2: Classification with DCCD ──────────────────────────────────────
-- The model reasons about the review before committing to a label.
-- Without DCCD, the grammar forces the first token to be a label -
-- the model has no chance to "think" about the input.

io.write("── 2. Classification with draft reasoning ───────────────────────\n")

local sentiment = Grammar.from_enum("root", { "positive", "negative", "neutral" })
local reviews = {
    "The battery lasts forever and the camera is stunning. Best phone I've owned.",
    "Arrived damaged. Support took 3 weeks to respond. Absolutely unacceptable.",
    "Works fine. Does what it says. No surprises.",
}

for _, review in ipairs(reviews) do
    local draft_s    = make_draft_sampler()
    local constrain_s = make_constrained_sampler(sentiment:to_gbnf())
    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = draft_s,
        constrain_sampler = constrain_s,
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
    })

    prefill({ { role = "user", content =
        string.format('Review: "%s"\nSentiment:', review)
    }})

    local r = dc:generate()
    io.write(string.format("  %-62s → %s\n",
        '"' .. review:sub(1, 58) .. '…"',
        r and r.text or "(nil)"))

    draft_s:free(); constrain_s:free()
end
io.write("\n")

-- ── Example 3: best_of(k) - multiple drafts, pick best ───────────────────────
-- Generate k unconstrained drafts. For each, inject into KV and run
-- constrained pass. Keep the result with the longest constrained output
-- (proxy for highest feasibility - see §Limitations in PUBLIC_API.md).

io.write("── 3. best_of(3) - pick most feasible draft ────────────────────\n")

local api_schema = Grammar.from_json_schema({
    type = "object",
    properties = {
        action = { enum = { "create", "read", "update", "delete" } },
        resource = { type = "string" },
        priority = { enum = { "low", "medium", "high", "critical" } },
    },
    required = { "action", "resource", "priority" },
})

local draft_s3    = make_draft_sampler()
local constrain_s3 = make_constrained_sampler(api_schema:to_gbnf())
local dc3 = Grammar.dccd(ctx, vocab, {
    draft_sampler     = draft_s3,
    constrain_sampler = constrain_s3,
    max_draft_tokens  = 96,
    max_final_tokens  = 96,
    best_of_k         = 3,    -- try 3 drafts
})

prefill({ { role = "user", content =
    "A critical production database is down. Generate an incident response action JSON."
}})

local r3 = dc3:best_of(3)
if r3 then
    io.write("  result:       " .. r3.text .. "\n")
    io.write(string.format("  winning draft (truncated): %q\n",
        r3.draft:sub(1, 70)))
    io.write(string.format("  tokens: draft=%d  constrained=%d\n\n",
        r3.n_draft_toks, r3.n_tokens))
end

draft_s3:free(); constrain_s3:free()

-- ── Example 4: streaming both passes ─────────────────────────────────────────
-- on_draft_token and on_final_token let you stream each pass in real time.
-- Useful for showing the model's reasoning alongside the structured output.

io.write("── 4. Streaming draft and final pass ───────────────────────────\n")

local enum_g = Grammar.from_enum("root",
    { "LuaJIT", "Python", "Go", "Rust", "JavaScript", "C", "C++" })

local draft_pieces = {}
local dc4 = Grammar.dccd(ctx, vocab, {
    draft_sampler     = make_draft_sampler(),
    constrain_sampler = make_constrained_sampler(enum_g:to_gbnf()),
    max_draft_tokens  = 80,
    max_final_tokens  = 20,
    on_draft_token    = function(p)
        draft_pieces[#draft_pieces + 1] = p
    end,
    on_final_token    = function(p)
        io.write(p); io.flush()
    end,
})

prefill({ { role = "user", content =
    "Which programming language is best for embedding scripting in a C application? One word answer."
}})

io.write("  draft (hidden from user): streaming silently...\n")
io.write("  final: ")
local r4 = dc4:generate()
io.write("\n")
if r4 then
    io.write(string.format("  [draft was %d tokens: %q]\n\n",
        r4.n_draft_toks,
        table.concat(draft_pieces):sub(1, 60)))
end

-- ── Cleanup ───────────────────────────────────────────────────────────────────

ctx:free()
model:free()
ion7.shutdown()

io.write("══ done ═══════════════════════════════════════════════════════\n")
