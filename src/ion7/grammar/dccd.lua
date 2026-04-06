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
---     requires per-step logit access before grammar masking, which is not yet
---     exposed by the ion7-core sampler API (planned for v1.1).
---   - With k=1 (the default), our implementation is fully faithful to the paper.
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
--- @field private _ctx      any      ion7-core Context.
--- @field private _vocab    any      ion7-core Vocab.
--- @field private _draft_s  any      Unconstrained draft sampler.
--- @field private _final_s  any      Grammar-constrained sampler.
--- @field private _max_d    number   Max tokens for the draft pass.
--- @field private _max_f    number   Max tokens for the final constrained pass.
--- @field private _on_draft function? Callback invoked with each draft piece.
--- @field private _on_final function? Callback invoked with each final piece.
--- @field private _best_k   number   Number of drafts to generate and rank.
local DCCD = {}
DCCD.__index = DCCD

--- Create a DCCD generator.
---
--- @param  ctx    any    ion7-core Context (snapshot support required).
--- @param  vocab  any    ion7-core Vocab.
--- @param  opts   table
---   opts.draft_sampler      any       Unconstrained sampler for step 1.
---   opts.constrain_sampler  any       Grammar-constrained sampler for step 2.
---   opts.max_draft_tokens   number?   Max tokens in draft (default: 512).
---   opts.max_final_tokens   number?   Max tokens in final (default: 512).
---   opts.on_draft_token     function? Called with each draft piece.
---   opts.on_final_token     function? Called with each final piece.
---   opts.best_of_k          number?   Generate K drafts, use best (default: 1).
--- @return DCCD
function DCCD.new(ctx, vocab, opts)
    assert(ctx,   "[ion7.grammar.dccd] ctx required")
    assert(vocab, "[ion7.grammar.dccd] vocab required")
    assert(opts and opts.draft_sampler,
        "[ion7.grammar.dccd] opts.draft_sampler required")
    assert(opts.constrain_sampler,
        "[ion7.grammar.dccd] opts.constrain_sampler required")

    return setmetatable({
        _ctx      = ctx,
        _vocab    = vocab,
        _draft_s  = opts.draft_sampler,
        _final_s  = opts.constrain_sampler,
        _max_d    = opts.max_draft_tokens  or 512,
        _max_f    = opts.max_final_tokens  or 512,
        _on_draft = opts.on_draft_token,
        _on_final = opts.on_final_token,
        _best_k   = opts.best_of_k or 1,
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

    -- ── Step 1: Generate K unconstrained drafts ───────────────────────────────
    -- For K=1, stream via on_draft_token. For K>1, suppress streaming because
    -- we cannot know the winning draft until all constrained passes complete.
    local stream_draft = (best_k == 1) and self._on_draft or nil
    local drafts = {}

    for _ = 1, best_k do
        ctx:restore(pre_snap)
        ctx._n_past = pre_n
        local text, toks = self:_run_pass(self._draft_s, max_d, stream_draft)
        drafts[#drafts + 1] = { text = text, toks = toks }
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
    -- (not yet exposed in the sampler API). We approximate with constrained
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
