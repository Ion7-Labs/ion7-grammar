--- @module ion7.grammar.runtime.backtrack
--- SPDX-License-Identifier: MIT
--- Grammar-guided generation with KV-cache backtracking (IterGen / CRANE).
---
--- Inspired by IterGen (ICLR 2025). Implemented natively in Lua using
--- ion7-core's `ctx:snapshot()` / `ctx:restore()` and `ctx:kv_seq_rm()`.
---
--- When a semantic constraint fails (wrong table name, invalid reference,
--- forbidden pattern), Backtrack:
---   1. Restores the KV cache to just before the bad fragment
---   2. Resamples only that fragment (up to `max_retries` times)
---   3. Continues generation from the corrected point
---
--- Requires ion7-core (not available in pure-Lua mode).
---
--- @usage
---   local bt = Grammar.backtrack(ctx, vocab, sampler)
---
---   bt:checkpoint("tbl")                -- save KV position
---   bt:forward(function(p) return p:find("%s") end)  -- gen until space
---   bt:constrain("tbl", function(text)  -- validate; rollback if false
---       return db:has_table(text:match("(%w+)$"))
---   end)
---   local result = bt:run()
---
--- @author Ion7-Labs
--- @version 0.1.0

--- @class Backtrack
local Backtrack = {}
Backtrack.__index = Backtrack

--- Create a Backtrack session.
---
--- @param  ctx      any     ion7-core Context (snapshot support required).
--- @param  vocab    any     ion7-core Vocab.
--- @param  sampler  any     ion7-core Sampler (grammar-constrained).
--- @param  opts     table?
---   opts.max_tokens    number?    Hard limit per generation (default: 2048).
---   opts.max_retries   number?    Max retries per backward() call (default: 10).
---   opts.on_token      function?  Called with each accepted piece.
function Backtrack.new(ctx, vocab, sampler, opts)
    assert(ctx,     "[ion7.grammar.runtime.backtrack] ctx required")
    assert(vocab,   "[ion7.grammar.runtime.backtrack] vocab required")
    assert(sampler, "[ion7.grammar.runtime.backtrack] sampler required")
    opts = opts or {}

    return setmetatable({
        _ctx         = ctx,
        _vocab       = vocab,
        _sampler     = sampler,
        _max_tokens  = opts.max_tokens  or 2048,
        _max_retries = opts.max_retries or 10,
        _on_token    = opts.on_token,
        _tokens      = {},
        _pieces      = {},
        _n_generated = 0,
        _symbols     = {},
        _snapshots   = {},
        _done        = false,
        _stop_reason = nil,
    }, Backtrack)
end

-- ── Internal: generate one token ─────────────────────────────────────────────

--- @private
function Backtrack:_gen_one(batch_idx)
    local ctx     = self._ctx
    local vocab   = self._vocab
    local sampler = self._sampler

    local tok = sampler:sample(ctx:ptr(), batch_idx or -1)
    -- Note: llama_sampler_sample() already calls llama_sampler_accept() internally.
    -- Do NOT call sampler:accept(tok) - double-accept corrupts grammar state.
    if vocab:is_eog(tok) then
        self._done = true
        self._stop_reason = "stop"
        return nil
    end

    ctx:decode_single(tok, 0)

    local piece = vocab:piece(tok)
    self._tokens[#self._tokens + 1]  = tok
    self._pieces[#self._pieces + 1]  = piece
    self._n_generated = self._n_generated + 1

    if self._on_token then pcall(self._on_token, piece) end

    return tok, piece
end

--- @private
function Backtrack:_save_snapshot()
    local idx  = #self._tokens
    local blob = self._ctx:snapshot()
    self._snapshots[idx] = { blob = blob, n_past = self._ctx:n_past() }
    return idx
end

--- @private
function Backtrack:_restore_to(snap_idx)
    local snap = self._snapshots[snap_idx]
    if not snap then
        error(string.format(
            "[ion7.grammar.runtime.backtrack] no snapshot at token %d", snap_idx))
    end
    self._ctx:restore(snap.blob)
    self._ctx:set_n_past(snap.n_past)
    self._sampler:reset()

    for i = #self._tokens, snap_idx + 1, -1 do
        self._tokens[i] = nil
        self._pieces[i] = nil
    end
    self._n_generated = snap_idx
    self._done = false
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Register a grammar symbol checkpoint.
--- Saves a KV snapshot at the current position and associates it with a name.
--- @param  symbol  string  Symbol name (e.g. "field_name", "table_ref").
--- @return number  Token index of this checkpoint.
function Backtrack:checkpoint(symbol)
    local idx = self:_save_snapshot()
    if not self._symbols[symbol] then self._symbols[symbol] = {} end
    self._symbols[symbol][#self._symbols[symbol] + 1] = idx
    return idx
end

--- Generate tokens until a predicate returns true or max_tokens reached.
--- @param  predicate  function?  Called after each token with (piece, all_text).
---                    Return true to stop, false to continue.
--- @param  max        number?    Override max_tokens for this call.
--- @return string  All text generated so far.
function Backtrack:forward(predicate, max)
    max = max or self._max_tokens

    for _ = 1, max do
        if self._done then break end
        if self._n_generated >= self._max_tokens then
            self._done = true
            self._stop_reason = "length"
            break
        end

        local tok, piece = self:_gen_one()
        if not tok then break end

        if predicate then
            local all = table.concat(self._pieces)
            if predicate(piece, all) then break end
        end
    end

    return table.concat(self._pieces)
end

--- Backtrack to the last checkpoint for a symbol and resample.
--- @param  symbol     string    Symbol name to rewind to.
--- @param  validator  function? Called with (new_text) after resample.
---                    Return true to accept, false to retry.
--- @return boolean  true if accepted, false if max_retries exhausted.
function Backtrack:backward(symbol, validator)
    local checkpoints = self._symbols[symbol]
    if not checkpoints or #checkpoints == 0 then
        error("[ion7.grammar.runtime.backtrack] no checkpoint for symbol: " .. symbol)
    end

    local snap_idx = checkpoints[#checkpoints]

    for _ = 1, self._max_retries do
        self:_restore_to(snap_idx)

        local tok, piece = self:_gen_one()
        if not tok then
            return false
        end

        if validator then
            local accepted = validator(piece, table.concat(self._pieces))
            if accepted then return true end
        else
            return true
        end
    end

    return false
end

--- Return the full generated text so far.
--- @return string
function Backtrack:text()
    return table.concat(self._pieces)
end

--- Return whether generation is complete.
--- @return boolean  done
--- @return string?  stop_reason  "stop" | "length" | nil
function Backtrack:is_done()
    return self._done, self._stop_reason
end

--- Return the last checkpoint index for a symbol.
--- @param  symbol  string
--- @return number?
function Backtrack:last_checkpoint(symbol)
    local c = self._symbols[symbol]
    return c and c[#c]
end

--- Number of tokens generated so far.
--- @return number
function Backtrack:n_tokens()
    return self._n_generated
end

--- Apply a semantic constraint at the current position (CRANE pattern).
---
--- If the validator fails on the current text, rolls back to the last
--- checkpoint for `symbol` and re-runs `forward` (using `opts.forward_pred`
--- and `opts.max_forward`) before re-validating.  This mirrors how `run()`
--- uses constrain: checkpoint → forward → constrain, so retries must repeat
--- the forward pass to produce a complete new candidate.
---
--- @param  symbol     string    Checkpoint symbol to backtrack to on failure.
--- @param  validator  function  fn(text) → boolean.
--- @param  opts       table?
---   opts.max_retries   number?
---   opts.forward_pred  function?  Stop predicate for the re-forward pass
---                                 (same one used in the original forward call).
---   opts.max_forward   number?    Token limit for the re-forward pass.
---   opts.on_retry      function?
--- @return boolean
function Backtrack:constrain(symbol, validator, opts)
    opts = opts or {}
    local max_retries  = opts.max_retries  or self._max_retries
    local forward_pred = opts.forward_pred
    local max_forward  = opts.max_forward

    if validator(self:text()) then return true end

    local checkpoints = self._symbols[symbol]
    if not checkpoints or #checkpoints == 0 then
        error("[ion7.grammar.runtime.backtrack] no checkpoint for symbol: " .. symbol)
    end
    local snap_idx = checkpoints[#checkpoints]

    for attempt = 1, max_retries do
        if opts.on_retry then pcall(opts.on_retry, attempt) end
        self:_restore_to(snap_idx)

        -- Re-run forward to build a complete new candidate before validating.
        if forward_pred then
            self:forward(forward_pred, max_forward)
        else
            -- No forward_pred: generate a single token (legacy behaviour,
            -- works when the checkpoint is at a single-token decision point).
            local tok = self:_gen_one()
            if not tok then return false end
        end

        if validator(self:text()) then return true end
    end

    return false
end

--- Run a complete constrained generation loop with automatic backtracking.
---
--- @param  steps  table  Array of step tables:
---   step.symbol      string     Checkpoint name.
---   step.until_pred  function?  Stop predicate passed to forward().
---   step.max_tokens  number?    Token limit for the forward pass.
---   step.validator   function?  fn(text) → boolean, passed to constrain().
---   step.max_retries number?    Override max_retries for this step.
--- @return string   text  Full generated text.
--- @return boolean  ok    true if all constraints satisfied.
function Backtrack:run(steps)
    local all_ok = true
    for _, step in ipairs(steps) do
        if self._done then break end

        self:checkpoint(step.symbol)
        self:forward(step.until_pred, step.max_tokens)

        if step.validator then
            local ok = self:constrain(step.symbol, step.validator, {
                max_retries  = step.max_retries,
                forward_pred = step.until_pred,   -- re-forward on retry
                max_forward  = step.max_tokens,
            })
            if not ok then all_ok = false end
        end
    end
    return self:text(), all_ok
end

return Backtrack
