--- @module ion7.grammar.dccd
--- SPDX-License-Identifier: MIT
--- Draft-Conditioned Constrained Decoding (DCCD) for ion7-grammar.
---
--- Implementation of the DCCD algorithm (arXiv:2603.03305, Feb 2026)
--- using ion7-core's KV cache snapshot/restore primitives.
---
--- The problem with standard constrained decoding:
---   When the grammar forces tokens the model wouldn't naturally pick,
---   the probability distribution gets distorted token by token - the
---   "projection tax". This cascades into semantically wrong outputs
---   that are nonetheless syntactically valid.
---
--- DCCD solution (two-step, training-free):
---   Step 1: Generate an unconstrained draft y ~ p_draft(x).
---   Step 2: Restore KV to post-prompt, decode draft tokens into the KV cache,
---           then run grammar-constrained decoding on the augmented context
---           (prompt + draft + constrained_tokens_so_far).
---   The draft shifts probability mass toward valid continuations, reducing the
---   "projection tax". The model attends to its own unconstrained plan while
---   being forced to produce grammar-valid tokens.
---
--- Our implementation leverages ion7-core:
---   - ctx:snapshot() / ctx:restore()  - KV cache checkpointing
---   - ctx:decode_single()             - token-by-token KV injection
---   - Two samplers: free (step 1) and grammar-constrained (step 2)
---
--- Accuracy improvements per the paper: +24pp on structured reasoning (GSM8K).
--- Win rate vs standard constrained decoding: ~80% on summarization tasks.
---
--- Limitations vs the paper:
---   - best_of_k selection uses constrained output length as a proxy for the
---     paper's cumulative log feasible mass S(k) = Σ log(α̃_t). Exact S(k)
---     requires the per-step probability mass of valid tokens before grammar
---     masking. ion7_csampler with grammar_first=0 defers grammar to last and
---     gives access to the pre-grammar distribution, but
---     ion7_csampler_get_candidates() is not exposed in the bridge.
---   - With k=1 (the default), our implementation is fully faithful to the paper.
---   - When spec_draft_fn is provided, best_of_k is forced to 1 (n-gram drafts
---     are deterministic; running K identical drafts is pointless).
---
--- @usage
---   local dc = DCCD.new(ctx, vocab, {
---       draft_sampler     = ion7.Sampler.chain():temperature(0.8):dist():build(vocab),
---       constrain_sampler = ion7.Sampler.chain():grammar(gbnf, "root", vocab._ptr)
---                               :temperature(0.2):dist():build(vocab),
---       max_draft_tokens  = 256,
---       max_final_tokens  = 256,
---   })
---
---   -- Generate: draft → constrain
---   local resp = dc:generate()
---   print(resp.text)   -- guaranteed grammar-valid
---   print(resp.draft)  -- the unconstrained draft (for debugging)
---
--- @author Ion7-Labs
--- @version 0.1.0

--- @class DCCD
--- @field private _ctx         any       ion7-core Context.
--- @field private _vocab       any       ion7-core Vocab.
--- @field private _draft_s     any       Unconstrained draft sampler (nil when _spec_fn set).
--- @field private _final_s     any       Grammar-constrained sampler.
--- @field private _max_d       number    Max tokens for the draft pass.
--- @field private _max_f       number    Max tokens for the final constrained pass.
--- @field private _on_draft    function? Callback invoked with each draft piece.
--- @field private _on_final    function? Callback invoked with each final piece.
--- @field private _best_k      number    Number of drafts to generate and rank.
--- @field private _spec_fn     function? Fast-draft via ion7_speculative_draft (optional).
--- @field private _close_think string?   Closing sequence injected between draft and constrained pass (nil = disabled).
local DCCD = {}
DCCD.__index = DCCD

--- Create a DCCD generator.
---
--- @param  ctx    any    ion7-core Context (snapshot support required).
--- @param  vocab  any    ion7-core Vocab.
--- @param  opts   table
---   opts.draft_sampler      any       Unconstrained sampler for step 1.
---                                     Optional when spec_draft_fn is provided.
---   opts.constrain_sampler  any       Grammar-constrained sampler for step 2.
---   opts.max_draft_tokens   number?   Max tokens in draft (default: 512).
---   opts.max_final_tokens   number?   Max tokens in final (default: 512).
---   opts.on_draft_token     function? Called with each draft piece.
---   opts.on_final_token     function? Called with each final piece.
---   opts.best_of_k          number?   Generate K drafts, use best (default: 1).
---   opts.close_thinking     boolean|string?
---     When true, injects "\n</think>\n" between the draft and the constrained
---     pass.  Pass a custom string to override the closing sequence.
---     Use this with thinking models (Qwen3.5, DeepSeek-R1): the draft sampler
---     generates inside a <think> block that is never closed; without this flag
---     the constrained pass runs while the model believes it is still reasoning,
---     which corrupts the answer.
---   opts.spec_draft_fn      function? Fast draft via ion7_speculative_draft.
---     Signature: spec_draft_fn(last_tok) → tokens_array
---     When provided, replaces the full-decode draft pass with an O(1) n-gram
---     lookup (ion7_speculative NGRAM_CACHE / NGRAM_SIMPLE).  draft_sampler is
---     not used in this path.  best_of_k is forced to 1 (n-gram drafts are
---     deterministic — running K identical drafts is pointless).
---
---     Example:
---       local ffi = require "ffi"
---       local out  = ffi.new("int32_t[64]")
---       local function my_spec(last_tok)
---           local n = B.ion7_speculative_draft(
---               spec, prompt_toks, n_prompt, last_tok, out, 64)
---           local toks = {}
---           for i = 0, tonumber(n)-1 do toks[#toks+1] = tonumber(out[i]) end
---           return toks
---       end
---       local dc = Grammar.dccd(ctx, vocab, {
---           spec_draft_fn     = my_spec,
---           constrain_sampler = ...,
---       })
--- @return DCCD
function DCCD.new(ctx, vocab, opts)
    assert(ctx,   "[ion7.grammar.dccd] ctx required")
    assert(vocab, "[ion7.grammar.dccd] vocab required")
    assert(opts,  "[ion7.grammar.dccd] opts required")
    assert(opts.constrain_sampler,
        "[ion7.grammar.dccd] opts.constrain_sampler required")
    -- draft_sampler is required only when spec_draft_fn is NOT provided
    assert(opts.spec_draft_fn or opts.draft_sampler,
        "[ion7.grammar.dccd] opts.draft_sampler required (or provide opts.spec_draft_fn)")

    local close_think
    if opts.close_thinking == true then
        close_think = "\n</think>\n"
    elseif type(opts.close_thinking) == "string" then
        close_think = opts.close_thinking
    end

    return setmetatable({
        _ctx         = ctx,
        _vocab       = vocab,
        _draft_s     = opts.draft_sampler,
        _final_s     = opts.constrain_sampler,
        _max_d       = opts.max_draft_tokens  or 512,
        _max_f       = opts.max_final_tokens  or 512,
        _on_draft    = opts.on_draft_token,
        _on_final    = opts.on_final_token,
        _best_k      = opts.best_of_k or 1,
        _spec_fn     = opts.spec_draft_fn,
        _close_think = close_think,
    }, DCCD)
end

-- ── Internal: run one generation pass ────────────────────────────────────────

--- Run a single generation pass with the given sampler up to max_tokens.
--- Resets the sampler before starting.  Decodes each accepted token into ctx
--- and calls on_token (if provided) with the decoded text piece.
--- @private
--- @param  sampler    any       Sampler to drive this pass.
--- @param  max_tokens number    Maximum tokens to generate.
--- @param  on_token   function? Called with (piece) for each accepted token.
--- @return string  Concatenated text of all generated pieces.
--- @return table   Array of generated token IDs.
function DCCD:_run_pass(sampler, max_tokens, on_token)
    local ctx   = self._ctx
    local vocab = self._vocab
    local pieces = {}
    local tokens = {}

    sampler:reset()
    for _ = 1, max_tokens do
        local tok = sampler:sample(ctx:ptr(), -1)
        -- Note: llama_sampler_sample() already calls llama_sampler_accept()
        -- internally. Do NOT call sampler:accept(tok) here - that would be a
        -- double-accept and corrupts grammar sampler state (→ crash).
        if vocab:is_eog(tok) then break end
        ctx:decode_single(tok, 0)
        local piece = vocab:piece(tok)
        pieces[#pieces+1] = piece
        tokens[#tokens+1] = tok
        if on_token then pcall(on_token, piece) end
    end
    return table.concat(pieces), tokens
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Generate using Draft-Conditioned Constrained Decoding.
---
--- Implements the algorithm from arXiv:2603.03305 (Feb 2026).
---
--- Requires ctx to already have the prompt decoded (n_past set correctly).
--- Call after your pipeline has run ctx:decode(prompt_tokens).
---
--- **Context size note**: the KV cache must have room for
---   n_ctx >= prompt_tokens + max_draft_tokens + max_final_tokens
--- because the draft tokens are injected before the constrained pass.
---
--- **best_of_k note**: with k > 1, streaming callbacks are suppressed during
--- draft generation (we don't know the winner yet). The winning draft's pieces
--- are replayed through on_draft_token after selection.
---
--- @param  opts  table?
---   opts.max_draft_tokens  number?  Override for this call.
---   opts.max_final_tokens  number?  Override for this call.
---   opts.best_of_k         number?  Override number of drafts.
--- @return table?
---   { text, draft, tokens, draft_tokens, stop_reason, n_tokens, n_draft_toks }
---   Returns nil only if best_k < 1 (should never happen in practice).
function DCCD:generate(opts)
    opts = opts or {}
    local ctx    = self._ctx
    local vocab  = self._vocab
    local max_d  = opts.max_draft_tokens or self._max_d
    local max_f  = opts.max_final_tokens or self._max_f
    local best_k = opts.best_of_k or self._best_k

    -- Snapshot KV state at post-prompt position.
    -- Every draft+constrained pair restores to this point.
    local pre_snap = ctx:snapshot()
    local pre_n    = ctx._n_past

    -- ── Step 1: Generate unconstrained draft(s) ──────────────────────────────
    -- Two paths:
    --   A) spec_draft_fn provided → O(1) n-gram lookup, single deterministic
    --      draft (best_k forced to 1 — identical n-gram lookups are pointless).
    --   B) draft_sampler → full decode pass, supports best_of_k.
    local drafts = {}

    if self._spec_fn then
        -- Fast path: speculative n-gram draft (no decode, no GPU, microseconds)
        -- Grab the last token in the context to seed the n-gram lookup.
        -- ctx._n_past > 0 is guaranteed (caller must have decoded the prompt).
        local last_tok = ctx._last_tok or 0  -- set by Context.decode_single
        ctx:restore(pre_snap)
        ctx._n_past = pre_n

        local spec_toks = self._spec_fn(last_tok) or {}
        if #spec_toks > 0 then
            local pieces = {}
            for _, tok in ipairs(spec_toks) do
                pieces[#pieces + 1] = vocab:piece(tok)
            end
            drafts[1] = { text = table.concat(pieces), toks = spec_toks }
        else
            -- N-gram miss: fall back to a single full draft pass
            local text, toks = self:_run_pass(self._draft_s or self._final_s,
                                               max_d, self._on_draft)
            drafts[1] = { text = text, toks = toks }
        end
    else
        -- Standard path: K full decode passes
        -- For K=1, stream via on_draft_token. For K>1, suppress (winner unknown).
        local stream_draft = (best_k == 1) and self._on_draft or nil
        for _ = 1, best_k do
            ctx:restore(pre_snap)
            ctx._n_past = pre_n
            local text, toks = self:_run_pass(self._draft_s, max_d, stream_draft)
            drafts[#drafts + 1] = { text = text, toks = toks }
        end
    end

    -- ── Step 2: For each draft, inject into KV then run constrained pass ──────
    -- Per arXiv:2603.03305 §3: the draft y is decoded into the KV cache before
    -- the constrained pass, so the model attends to (prompt + draft + z<t).
    -- This shifts probability mass toward valid continuations that align with
    -- the unconstrained plan, reducing the "projection tax" of grammar masking.
    --
    -- Draft selection: the paper uses cumulative log feasible mass
    --   S(k) = Σ_t log(α̃_t),  α̃_t = Pr[next token ∈ valid set | context]
    -- Exact computation requires per-step logit access before grammar masking
    -- (ion7_csampler_get_candidates not exposed in bridge). We approximate with constrained
    -- output length: longer output → higher cumulative feasibility.
    local best_result = nil
    local best_len    = -1

    for _, draft in ipairs(drafts) do
        -- Restore to post-prompt state
        ctx:restore(pre_snap)
        ctx._n_past = pre_n

        -- *** Core of DCCD: inject draft tokens into the KV cache. ***
        -- The constrained sampler now attends to (prompt + draft) as history.
        for _, tok in ipairs(draft.toks) do
            ctx:decode_single(tok, 0)
        end

        -- Thinking-model fix: close the <think> block opened by the generation
        -- prefix before the constrained pass.  Without this, models like Qwen3.5
        -- treat the constrained tokens as part of the reasoning chain rather than
        -- the final answer, producing semantically wrong output.
        local n_close = 0
        if self._close_think then
            local close_toks, n = vocab:tokenize(self._close_think, false, true)
            for i = 0, n - 1 do
                ctx:decode_single(close_toks[i], 0)
            end
            n_close = n
        end

        -- Run constrained generation on augmented context (prompt + draft + z<t)
        local final_text, final_toks = self:_run_pass(
            self._final_s, max_f, self._on_final)

        -- Keep the candidate with the longest constrained output (feasibility proxy)
        if #final_toks > best_len then
            best_len = #final_toks
            best_result = {
                text         = final_text,
                draft        = draft.text,
                tokens       = final_toks,
                draft_tokens = draft.toks,
                stop_reason  = "stop",
                n_tokens     = #final_toks,
                n_draft_toks = #draft.toks,
                n_close_toks = n_close,
            }
        end
    end

    -- For K>1: replay winning draft through the callback now that we know the winner.
    -- Reconstruct pieces from token IDs via vocab to preserve original token boundaries.
    if best_k > 1 and self._on_draft and best_result then
        for _, tok in ipairs(best_result.draft_tokens) do
            pcall(self._on_draft, vocab:piece(tok))
        end
    end

    return best_result
end

--- Convenience: run DCCD with best-of-K draft selection.
---
--- Generates K drafts, selects the one where the constrained pass
--- produces the longest (most complete) output - a proxy for quality.
---
--- @param  k     number  Number of drafts to try.
--- @param  opts  table?  Same as generate().
--- @return table?  Best result across K attempts.
function DCCD:best_of(k, opts)
    opts = opts or {}
    opts.best_of_k = k
    return self:generate(opts)
end

return DCCD
