--- @module ion7.grammar.runtime.dccd
--- SPDX-License-Identifier: MIT
--- Draft-Conditioned Constrained Decoding (DCCD, arXiv:2603.03305).
---
--- Standard constrained decoding distorts the token probability distribution
--- step by step — the "projection tax" — producing outputs that are
--- syntactically valid but semantically wrong.
---
--- DCCD fixes this in two training-free steps:
---   1. Generate an unconstrained draft `y ~ p_draft(x)`.
---   2. Restore KV to post-prompt, inject the draft tokens, then run
---      grammar-constrained decoding on the augmented context. The model
---      attends to its own unconstrained plan while being forced to produce
---      grammar-valid tokens.
---
--- Accuracy gains per the paper: +24 pp on structured reasoning (GSM8K).
--- Win rate vs standard constrained decoding: ~80% on summarization.
---
--- Requires ion7-core (uses `ctx:snapshot()` / `ctx:restore()`).
---
--- @usage
---   local dc = Grammar.dccd(ctx, vocab, {
---       draft_sampler     = free_sampler,
---       constrain_sampler = grammar_sampler,
---       max_draft_tokens  = 128,
---       close_thinking    = true,   -- required for Qwen3.5 / DeepSeek-R1
---   })
---   local result = dc:generate()
---   print(result.text)   -- grammar-valid output
---   print(result.draft)  -- unconstrained draft for debugging
---
--- @author Ion7-Labs
--- @version 0.1.0

--- @class DCCD
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
---     not used in this path.  best_of_k is forced to 1.
--- @return DCCD
function DCCD.new(ctx, vocab, opts)
    assert(ctx,   "[ion7.grammar.runtime.dccd] ctx required")
    assert(vocab, "[ion7.grammar.runtime.dccd] vocab required")
    assert(opts,  "[ion7.grammar.runtime.dccd] opts required")
    assert(opts.constrain_sampler,
        "[ion7.grammar.runtime.dccd] opts.constrain_sampler required")
    assert(opts.spec_draft_fn or opts.draft_sampler,
        "[ion7.grammar.runtime.dccd] opts.draft_sampler required (or provide opts.spec_draft_fn)")

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
        _last_tok    = 0,
    }, DCCD)
end

-- ── Internal: run one generation pass ────────────────────────────────────────

--- @private
function DCCD:_run_pass(sampler, max_tokens, on_token)
    local ctx   = self._ctx
    local vocab = self._vocab
    local pieces = {}
    local tokens = {}

    sampler:reset()
    for _ = 1, max_tokens do
        local tok = sampler:sample(ctx:ptr(), -1)
        -- Note: llama_sampler_sample() already calls llama_sampler_accept()
        -- internally. Do NOT call sampler:accept(tok) here - double-accept
        -- corrupts grammar sampler state.
        if vocab:is_eog(tok) then break end
        ctx:decode_single(tok, 0)
        self._last_tok = tok
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
--- @param  opts  table?
---   opts.max_draft_tokens  number?  Override for this call.
---   opts.max_final_tokens  number?  Override for this call.
---   opts.best_of_k         number?  Override number of drafts.
---   opts.last_token        number?  Last token currently in ctx (seeds
---                                   spec_draft_fn on the first call).
--- @return table?
---   { text, draft, tokens, draft_tokens, stop_reason, n_tokens, n_draft_toks }
function DCCD:generate(opts)
    opts = opts or {}
    local ctx    = self._ctx
    local vocab  = self._vocab
    local max_d  = opts.max_draft_tokens or self._max_d
    local max_f  = opts.max_final_tokens or self._max_f
    local best_k = opts.best_of_k or self._best_k

    local pre_snap = ctx:snapshot()
    local pre_n    = ctx._n_past

    -- ── Step 1: Generate unconstrained draft(s) ──────────────────────────────
    local drafts = {}

    if self._spec_fn then
        -- Fast path: speculative n-gram draft (no decode, no GPU, microseconds).
        local last_tok = opts.last_token or self._last_tok
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
    local best_result = nil
    local best_len    = -1

    for _, draft in ipairs(drafts) do
        ctx:restore(pre_snap)
        ctx._n_past = pre_n

        -- Inject draft tokens into the KV cache (core of DCCD)
        for _, tok in ipairs(draft.toks) do
            ctx:decode_single(tok, 0)
        end

        -- Thinking-model fix: close the <think> block opened by the generation
        -- prefix before the constrained pass.
        local n_close = 0
        if self._close_think then
            local close_toks, n = vocab:tokenize(self._close_think, false, true)
            for i = 0, n - 1 do
                ctx:decode_single(close_toks[i], 0)
            end
            n_close = n
        end

        local final_text, final_toks = self:_run_pass(
            self._final_s, max_f, self._on_final)

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
    if best_k > 1 and self._on_draft and best_result then
        for _, tok in ipairs(best_result.draft_tokens) do
            pcall(self._on_draft, vocab:piece(tok))
        end
    end

    return best_result
end

--- Convenience: run DCCD with best-of-K draft selection.
--- @param  k     number  Number of drafts to try.
--- @param  opts  table?  Same as generate().
--- @return table?  Best result across K attempts.
function DCCD:best_of(k, opts)
    opts = opts or {}
    opts.best_of_k = k
    return self:generate(opts)
end

return DCCD
