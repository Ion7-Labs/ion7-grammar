#!/usr/bin/env luajit
--- DCCD model tests - requires a real GGUF model.
---
--- Verifies that Draft-Conditioned Constrained Decoding (arXiv:2603.03305)
--- works correctly end-to-end with a real model and real grammar samplers.
---
--- What these tests assert (hard failures):
---   ✓ Grammar validity  - final text always matches the declared grammar
---   ✓ DCCD structure    - draft is generated, non-empty, distinct from final
---   ✓ KV integrity      - n_past is correct, second call doesn't corrupt state
---   ✓ Callbacks         - streamed pieces reconstruct result fields exactly
---   ✓ API correctness   - all result fields present with correct types
---
--- What these tests print but do NOT assert (model-dependent):
---   ~ Semantic accuracy - whether the model's answer is factually correct.
---     This depends on model size. A 0.8B model may answer math incorrectly.
---     The test suite passes regardless; semantic accuracy is shown for inspection.
---
--- Run:
---   ION7_MODEL=/path/to/model.gguf \
---   ION7_CORE_PATH=../ion7-core \
---   luajit tests/test_dccd_model.lua
---
--- Optional:
---   LLAMA_LIB=/path/to/libllama.so   (if not on LD_LIBRARY_PATH)
---   ION7_LIB_DIR=/path/to/bridge/dir

-- ── Path setup ────────────────────────────────────────────────────────────────

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local core_path = os.getenv("ION7_CORE_PATH") or "../ion7-core"
package.path = core_path .. "/src/?.lua;" .. core_path .. "/src/?/init.lua;"
            .. package.path

-- ── Env ─────────────────────────────���─────────────────────────────────────────

local model_path = os.getenv("ION7_MODEL")
local lib_dir    = os.getenv("ION7_LIB_DIR")
local llama_lib  = os.getenv("LLAMA_LIB")

if not model_path then
    print("[SKIP] Set ION7_MODEL=/path/to/model.gguf to run DCCD model tests.")
    os.exit(0)
end

-- ── Load ──────────────────────────────────────────────────────────────────────

local T       = require "tests.framework"
local ion7    = require "ion7.core"
local Grammar = require "ion7.grammar"

ion7.init({ log_level = 0, llama_path = lib_dir, bridge_path = lib_dir,
            llama_lib = llama_lib })

-- ── Model / Vocab / Context ───────────────────────────────────────────────────

-- Context must fit: prompt + max_draft_tokens + max_final_tokens
local N_CTX = 512

-- Thinking models (Qwen3.5, DeepSeek-R1) open a <think> block in the
-- generation prefix that is never closed by the draft pass.  The constrained
-- pass runs mid-think and produces wrong answers.  close_thinking=true injects
-- "\n</think>\n" between draft injection and the constrained pass.
-- Set to false when testing with a non-thinking model.
local CLOSE_THINKING = true

local fit   = ion7.Model.fit_params(model_path, { n_ctx_min = N_CTX })
local model = ion7.Model.load(model_path, {
    n_gpu_layers = fit and fit.n_gpu_layers or 0,
})
assert(model, "Model.load() failed - check ION7_MODEL path")

local vocab = model:vocab()
local ctx   = model:context({ n_ctx = N_CTX, offload_kqv = true })
assert(ctx, "Context.create() failed")

print(string.format("\n  Model loaded | n_ctx=%d | n_gpu_layers=%d",
    N_CTX, fit and fit.n_gpu_layers or 0))

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function prepare_chat(user_msg)
    local prompt = vocab:apply_template(
        {{ role = "user", content = user_msg }}, true)
    local tokens, n = vocab:tokenize(prompt, false, true)
    ctx:kv_clear()
    ctx:decode(tokens, n, 0, 0)
    return n
end

--- Run standard constrained generation (no DCCD) for comparison.
local function constrained_only(gbnf, max_tokens)
    local s = ion7.Sampler.chain()
        :grammar(gbnf, "root", vocab)
        :top_k(1):dist(42):build(vocab)
    local pieces = {}
    s:reset()
    for _ = 1, max_tokens do
        local tok = s:sample(ctx:ptr(), -1)
        -- sample() already calls llama_sampler_accept() - do NOT double-accept
        if vocab:is_eog(tok) then break end
        ctx:decode_single(tok, 0)
        pieces[#pieces + 1] = vocab:piece(tok)
    end
    return table.concat(pieces)
end

local function print_dccd(r, label)
    local sep = string.rep("─", 56)
    io.write(string.format("  %s\n  [%s]\n", sep, label or "DCCD"))
    io.write(string.format("  DRAFT  (%2d tok): %s\n",
        r.n_draft_toks, r.draft:sub(1, 100):gsub("\n", "\\n")))
    io.write(string.format("  FINAL  (%2d tok): %s\n  %s\n",
        r.n_tokens, r.text:sub(1, 100):gsub("\n", "\\n"), sep))
end

--- Check if final text is semantically correct and print result.
--- Returns true/false but does NOT call T.ok - just informational.
local function check_semantic(_, got, expected_values)
    local is_table = type(expected_values) == "table"
    local correct
    if is_table then
        for _, v in ipairs(expected_values) do
            if got == v then correct = true; break end
        end
    else
        correct = (got == expected_values)
    end
    local mark = correct and "✓" or "~"
    io.write(string.format("  %s semantic: got '%s'%s\n", mark, got,
        correct and "" or (" (expected: " .. (is_table
            and table.concat(expected_values, "|") or tostring(expected_values)) .. ")")))
    return correct
end

-- ═══════════════════════════════════════════════════��══════════════════════════
-- 1. API STRUCTURE - generate() returns all fields with correct types
-- ══════════════════════════════════════════════════════════════════════════════

T.suite("DCCD API structure")

T.test("generate() returns all expected fields with correct types", function()
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()
    prepare_chat("Is 2+2=4? Reply yes or no.")

    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:generate()
    T.ok(r ~= nil, "generate() returned non-nil")
    T.is_type(r.text,         "string",  "result.text is string")
    T.is_type(r.draft,        "string",  "result.draft is string")
    T.is_type(r.tokens,       "table",   "result.tokens is table")
    T.is_type(r.draft_tokens, "table",   "result.draft_tokens is table")
    T.is_type(r.n_tokens,     "number",  "result.n_tokens is number")
    T.is_type(r.n_draft_toks, "number",  "result.n_draft_toks is number")
    T.is_type(r.stop_reason,  "string",  "result.stop_reason is string")
    T.gt(r.n_tokens,     0, "final has at least 1 token")
    T.gt(r.n_draft_toks, 0, "draft has at least 1 token")
    T.ok(#r.tokens == r.n_tokens,         "r.tokens length == r.n_tokens")
    T.ok(#r.draft_tokens == r.n_draft_toks, "r.draft_tokens length == r.n_draft_toks")
    print_dccd(r, "API structure check")
    check_semantic("2+2=4", r.text, "yes")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. GRAMMAR VALIDITY - the hard invariant: final MUST match the grammar
-- ══════════════════════════════════════════════════════════════════════════════

T.suite("Grammar validity (hard invariant)")

T.test("enum grammar: final is one of the declared values", function()
    local cities = {"Paris", "London", "Berlin", "Rome", "Madrid"}
    local gbnf   = Grammar.from_enum("root", cities):to_gbnf()

    prepare_chat(
        "What is the capital of France? Reply with only the city name.")

    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 80,
        max_final_tokens  = 16,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:generate()
    print_dccd(r, "capital of France - enum")

    -- Hard: must be one of the 5 cities
    T.one_of(r.text, cities, "final is grammar-valid (one of 5 cities)")
    -- Soft: was it correct?
    check_semantic("capital of France", r.text, "Paris")
end)

T.test("regex grammar: final matches [0-9]+", function()
    local gbnf = Grammar.from_regex("[0-9]+"):to_gbnf()

    prepare_chat("What is 7 * 6? Reply with only the number.")

    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:generate()
    print_dccd(r, "7 * 6 - regex [0-9]+")

    -- Hard: must be all digits
    T.ok(r.text:match("^[0-9]+$") ~= nil,
        "final matches [0-9]+ (got: '" .. r.text .. "')")
    -- Soft: is it 42?
    check_semantic("7*6", r.text, "42")
end)

T.test("hand-built JSON grammar: final matches {answer:yes|no, confidence:int}", function()
    -- Tight grammar with no optional fields - structure is fully determined.
    local b = Grammar.builder()
    b:rule("root", Grammar.seq(
        Grammar.literal('{"answer":"'), Grammar.ref("answer"),
        Grammar.literal('","confidence":'), Grammar.ref("conf"),
        Grammar.literal("}")
    ))
    b:rule("answer", Grammar.alt(Grammar.literal("yes"), Grammar.literal("no")))
    b:rule("conf",   Grammar.alt(
        Grammar.literal("100"),
        Grammar.seq(Grammar.char("1-9"), Grammar.char("0-9")),
        Grammar.char("0-9")
    ))
    local gbnf = b:compile()

    prepare_chat(
        'Is Paris the capital of France? Reply ONLY as JSON: ' ..
        '{"answer":"yes" or "no","confidence":0 to 100}')

    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 96,
        max_final_tokens  = 32,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:generate()
    print_dccd(r, "JSON grammar")

    -- Hard: structure must match exactly
    T.ok(r.text:find('^{"answer":"') ~= nil, 'starts with {"answer":"')
    T.ok(r.text:find('"confidence":') ~= nil, 'contains "confidence":')
    T.ok(r.text:find('}$') ~= nil,           'ends with }')
    local conf_str = r.text:match('"confidence":(%d+)')
    T.ok(conf_str ~= nil, "confidence is a number")
    if conf_str then
        local conf = tonumber(conf_str)
        T.ok(conf >= 0 and conf <= 100,
            "confidence in [0,100] (got " .. conf .. ")")
    end
    -- Soft: was it yes?
    check_semantic("Paris is capital", r.text:match('"answer":"(%a+)"'), "yes")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. DCCD MECHANISM - draft ≠ final, draft is unconstrained, draft was injected
-- ══════════════════════════════════════════════════════════════════════════════

T.suite("DCCD mechanism")

T.test("draft is distinct from final (unconstrained vs constrained)", function()
    -- With a tight enum grammar, the draft (natural language) will be longer
    -- and structurally different from the grammar-constrained final.
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    prepare_chat("Is the sky blue? Answer yes or no.")
    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 128,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:generate()
    print_dccd(r, "sky is blue")
    T.one_of(r.text, {"yes", "no"}, "final is grammar-valid")
    T.gt(r.n_draft_toks, r.n_tokens,
        "draft longer than final (unconstrained explores more freely)")
end)

T.test("DCCD vs standard constrained: both grammar-valid, different context", function()
    -- Standard constrained runs on just (prompt).
    -- DCCD constrained runs on (prompt + draft).
    -- Both must be grammar-valid. They MAY differ (that's the point of DCCD).
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    -- Standard constrained
    prepare_chat("Is water H2O? Answer yes or no.")
    local std = constrained_only(gbnf, 8)

    -- DCCD
    prepare_chat("Is water H2O? Answer yes or no.")
    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
    })
    local r = dc:generate()

    print(string.format("  Standard constrained : '%s'", std))
    print_dccd(r, "DCCD")

    T.one_of(std,    {"yes", "no"}, "standard constrained: grammar-valid")
    T.one_of(r.text, {"yes", "no"}, "DCCD final: grammar-valid")
    -- Semantic note (informational only)
    check_semantic("water is H2O (std)", std, "yes")
    check_semantic("water is H2O (dccd)", r.text, "yes")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. KV CACHE INTEGRITY - n_past and multi-call correctness
-- ══════════════════════════════════════════════════════════════════════════════

T.suite("KV cache integrity")

T.test("n_past after generate() = prompt + n_draft_toks + n_tokens", function()
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    local n_prompt = prepare_chat("Is 3 a prime number? Answer yes or no.")

    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:generate()
    local expected = n_prompt + r.n_draft_toks + r.n_close_toks + r.n_tokens
    T.eq(ctx:n_past(), expected,
        string.format("n_past = prompt(%d) + draft(%d) + close(%d) + final(%d) = %d",
            n_prompt, r.n_draft_toks, r.n_close_toks, r.n_tokens, expected))
    print_dccd(r, "n_past check")
end)

T.test("second generate() call works correctly after first", function()
    -- Fresh prepare_chat before each call - verifies no KV corruption.
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    local function make_dc()
        return Grammar.dccd(ctx, vocab, {
            draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
            constrain_sampler = ion7.Sampler.chain()
                :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
            max_draft_tokens  = 64,
            max_final_tokens  = 8,
            close_thinking    = CLOSE_THINKING,
        })
    end

    prepare_chat("Is 2+2=4? Answer yes or no.")
    local r1 = make_dc():generate()

    prepare_chat("Is 2+2=5? Answer yes or no.")
    local r2 = make_dc():generate()

    T.one_of(r1.text, {"yes", "no"}, "first call: grammar-valid")
    T.one_of(r2.text, {"yes", "no"}, "second call: grammar-valid")
    T.gt(r1.n_draft_toks, 0, "first call: draft generated")
    T.gt(r2.n_draft_toks, 0, "second call: draft generated")

    print(string.format("  call 1 (2+2=4): draft='%s' final='%s'",
        r1.draft:sub(1,40):gsub("\n","\\n"), r1.text))
    print(string.format("  call 2 (2+2=5): draft='%s' final='%s'",
        r2.draft:sub(1,40):gsub("\n","\\n"), r2.text))

    check_semantic("2+2=4", r1.text, "yes")
    check_semantic("2+2=5", r2.text, "no")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 5. STREAMING CALLBACKS - pieces reconstruct result fields exactly
-- ══════════════════════════════════════════════════════════════════════════════

T.suite("Streaming callbacks")

T.test("on_draft_token and on_final_token reconstruct result exactly", function()
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    local draft_pieces = {}
    local final_pieces = {}

    prepare_chat("Is 2 a prime number? Answer yes or no.")

    local dc = Grammar.dccd(ctx, vocab, {
        draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
        on_draft_token    = function(p) draft_pieces[#draft_pieces+1] = p end,
        on_final_token    = function(p) final_pieces[#final_pieces+1] = p end,
    })

    local r = dc:generate()

    T.gt(#draft_pieces, 0, "on_draft_token fired at least once")
    T.gt(#final_pieces, 0, "on_final_token fired at least once")
    T.eq(table.concat(draft_pieces), r.draft,
        "streamed draft pieces == r.draft")
    T.eq(table.concat(final_pieces), r.text,
        "streamed final pieces == r.text")
    T.one_of(r.text, {"yes", "no"}, "grammar-valid")

    print(string.format("  draft cb: %d pieces → '%s'",
        #draft_pieces, r.draft:sub(1,40):gsub("\n","\\n")))
    print(string.format("  final cb: %d pieces → '%s'",
        #final_pieces, r.text))
    check_semantic("2 is prime", r.text, "yes")
end)

-- ══════════════════════════════════════════════════════════════════════════════
-- 6. BEST-OF-K - multiple drafts, constrained output from best context
-- ══════════════════════════════════════════════════════════════════════════════

T.suite("best_of_k")

T.test("best_of(3) returns grammar-valid output", function()
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    prepare_chat("Is 7 a prime number? Answer yes or no.")

    local dc = Grammar.dccd(ctx, vocab, {
        -- Temperature > 0 so the 3 drafts differ
        draft_sampler     = ion7.Sampler.chain()
            :temp(0.7):dist(os.time()):build(vocab),
        constrain_sampler = ion7.Sampler.chain()
            :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
        max_draft_tokens  = 64,
        max_final_tokens  = 8,
        close_thinking    = CLOSE_THINKING,
    })

    local r = dc:best_of(3)
    T.ok(r ~= nil,                            "best_of(3) returned a result")
    T.one_of(r.text, {"yes", "no"},           "best_of(3) final is grammar-valid")
    T.gt(r.n_draft_toks, 0,                   "a draft was selected")
    T.is_type(r.draft, "string",              "r.draft is string")

    print(string.format("  best_of(3): draft=%d tok, final='%s'",
        r.n_draft_toks, r.text))
    check_semantic("7 is prime", r.text, "yes")
end)

T.test("best_of(1) is equivalent to generate() with same greedy sampler", function()
    local gbnf = Grammar.from_enum("root", {"yes", "no"}):to_gbnf()

    local function make_dc_greedy()
        return Grammar.dccd(ctx, vocab, {
            draft_sampler     = ion7.Sampler.chain():top_k(1):dist(42):build(vocab),
            constrain_sampler = ion7.Sampler.chain()
                :grammar(gbnf, "root", vocab):top_k(1):dist(42):build(vocab),
            max_draft_tokens  = 64,
            max_final_tokens  = 8,
            close_thinking    = CLOSE_THINKING,
        })
    end

    prepare_chat("Is 11 a prime number? Answer yes or no.")
    local r1 = make_dc_greedy():generate()

    prepare_chat("Is 11 a prime number? Answer yes or no.")
    local r2 = make_dc_greedy():best_of(1)

    T.eq(r1.text, r2.text,
        "best_of(1) == generate() with greedy (reproducible)")
    T.one_of(r1.text, {"yes", "no"}, "grammar-valid")
    print(string.format("  generate()='%s'  best_of(1)='%s'", r1.text, r2.text))
end)

-- ══════════════════════════════════════════════════════════════════════���═══════

T.summary()
if T.fail > 0 then os.exit(1) end
