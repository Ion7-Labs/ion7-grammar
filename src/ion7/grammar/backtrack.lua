--- @module ion7.grammar.backtrack
--- SPDX-License-Identifier: MIT
--- Grammar-guided generation with backtracking via ion7-core KV cache.
---
--- This is our killer feature. Inspired by IterGen (ICLR 2025), implemented
--- natively in Lua using ion7-core's snapshot/restore and kv_seq_rm.
---
--- The idea: instead of decoding left-to-right with no recourse, we track
--- grammar symbol positions in the generated output. If a semantic constraint
--- fails (wrong table name, invalid reference, forbidden pattern), we:
---   1. Restore the KV cache to just before the bad fragment
---   2. Resample only that fragment
---   3. Continue generation
---
--- This is NOT available in any other Lua LLM library.
--- In Python, only IterGen does this (and without KV cache snapshots,
--- just token-level rewind which is slower).
---
--- @usage
---   local bt = Backtrack.new(ctx, vocab, sampler, grammar_string)
---
---   -- Generate until we hit a "field_name" symbol, validate it
---   local result = bt:forward("field_name", function(text, pos)
---       if not valid_column(text) then
---           -- Rewind to before this field_name and resample
---           bt:backward("field_name")
---           return false  -- retry
---       end
---       return true  -- accept
---   end)
---
--- @author Ion7-Labs
--- @version 0.1.0

--- @class Backtrack
--- @field private _ctx        any      ion7-core Context.
--- @field private _vocab      any      ion7-core Vocab.
--- @field private _sampler    any      ion7-core Sampler.
--- @field private _max_tokens  number  Hard token budget.
--- @field private _max_retries number  Max retries per backward() call.
--- @field private _on_token   function? Callback invoked with each accepted piece.
--- @field private _tokens     table   Generated token ID array.
--- @field private _pieces     table   Generated text-piece array.
--- @field private _n_generated number  Count of tokens generated so far.
--- @field private _symbols    table   symbol → array of checkpoint token indices.
--- @field private _snapshots  table   token_idx → { blob, n_past } KV snapshots.
--- @field private _done       boolean Whether generation has ended.
--- @field private _stop_reason string? "stop" | "length" | nil.
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
    assert(ctx,     "[ion7.grammar.backtrack] ctx required")
    assert(vocab,   "[ion7.grammar.backtrack] vocab required")
    assert(sampler, "[ion7.grammar.backtrack] sampler required")
    opts = opts or {}

    return setmetatable({
        _ctx         = ctx,
        _vocab       = vocab,
        _sampler     = sampler,
        _max_tokens  = opts.max_tokens  or 2048,
        _max_retries = opts.max_retries or 10,
        _on_token    = opts.on_token,
        -- Generation state
        _tokens      = {},     -- all generated token IDs
        _pieces      = {},     -- all generated text pieces
        _n_generated = 0,
        -- Symbol position map (symbol_name → array of {start_tok, end_tok})
        _symbols     = {},
        -- KV snapshots at key positions
        _snapshots   = {},     -- token_idx → { blob, n_past }
        _done        = false,
        _stop_reason = nil,
    }, Backtrack)
end

-- ── Internal: generate one token ─────────────────────────────────────────────

--- Sample and decode one token, appending it to the internal token/piece arrays.
--- Returns nil (and sets _done) when an end-of-generation token is produced.
--- @private
--- @param  batch_idx  number?  Batch position passed to sampler:sample() (default: -1).
--- @return number?  tok    Token ID, or nil on EOG.
--- @return string?  piece  Decoded text piece, or nil on EOG.
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

-- ── Save snapshot at current position ────────────────────────────────────────

--- Capture a KV-cache snapshot at the current token position.
--- Stores the snapshot blob and n_past in _snapshots keyed by token index.
--- @private
--- @return number  idx  Token index of the saved snapshot.
function Backtrack:_save_snapshot()
    local idx  = #self._tokens
    local blob = self._ctx:snapshot()
    self._snapshots[idx] = { blob = blob, n_past = self._ctx._n_past }
    return idx
end

-- ── Restore to a saved snapshot position ─────────────────────────────────────

--- Restore the KV cache and internal state to a previously saved snapshot.
--- Trims the token and piece arrays back to snap_idx and resets the sampler.
--- Errors if no snapshot exists at snap_idx.
--- @private
--- @param  snap_idx  number  Token index of the target snapshot (from _save_snapshot).
function Backtrack:_restore_to(snap_idx)
    local snap = self._snapshots[snap_idx]
    if not snap then
        error(string.format(
            "[ion7.grammar.backtrack] no snapshot at token %d", snap_idx))
    end
    self._ctx:restore(snap.blob)
    self._ctx._n_past = snap.n_past
    self._sampler:reset()

    -- Trim token/piece arrays back to snap_idx
    for i = #self._tokens, snap_idx + 1, -1 do
        self._tokens[i] = nil
        self._pieces[i] = nil
    end
    self._n_generated = snap_idx
    self._done = false
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Register a grammar symbol checkpoint.
--- Saves a KV snapshot at the current position and associates it with
--- a symbol name. Call this at logical boundaries in your generation loop.
---
--- @param  symbol  string  Symbol name (e.g. "field_name", "table_ref").
--- @return number  Token index of this checkpoint.
function Backtrack:checkpoint(symbol)
    local idx = self:_save_snapshot()
    if not self._symbols[symbol] then self._symbols[symbol] = {} end
    self._symbols[symbol][#self._symbols[symbol] + 1] = idx
    return idx
end

--- Generate tokens until a predicate returns true or max_tokens reached.
---
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
---
--- @param  symbol     string    Symbol name to rewind to.
--- @param  validator  function? Called with (new_text) after resample.
---                    Return true to accept, false to retry.
--- @return boolean  true if accepted, false if max_retries exhausted.
function Backtrack:backward(symbol, validator)
    local checkpoints = self._symbols[symbol]
    if not checkpoints or #checkpoints == 0 then
        error("[ion7.grammar.backtrack] no checkpoint for symbol: " .. symbol)
    end

    local snap_idx = checkpoints[#checkpoints]

    for _ = 1, self._max_retries do
        self:_restore_to(snap_idx)

        -- Resample forward until we hit another checkpoint or stop
        -- (caller decides when to stop via validator or subsequent forward())
        local tok, piece = self:_gen_one()
        if not tok then
            return false  -- EOG immediately = no valid token
        end

        if validator then
            local accepted = validator(piece, table.concat(self._pieces))
            if accepted then return true end
            -- else retry
        else
            return true  -- no validator = always accept first resample
        end
    end

    return false  -- exhausted retries
end

--- Return the full generated text so far.
--- @return string
function Backtrack:text()
    return table.concat(self._pieces)
end

--- Return whether generation is complete.
--- @return boolean  done         true when an EOG token was produced or max_tokens reached.
--- @return string?  stop_reason  "stop" | "length", or nil if not yet done.
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

--- Apply a semantic constraint at the current position.
---
--- This is the CRANE pattern (ICML 2025): combine free-form generation
--- (thinking, reasoning) with constrained final output.
---
--- The validator receives the text generated so far and returns:
---   - true  → constraint satisfied, continue
---   - false → constraint violated, backtrack to last checkpoint of `symbol`
---             and resample (up to max_retries times)
---
--- @param  symbol     string    Checkpoint symbol to backtrack to on failure.
--- @param  validator  function  fn(text) → boolean. Called with full generated text.
--- @param  opts       table?
---   opts.max_retries  number?  Override max retries (default: self._max_retries).
---   opts.on_retry     function? Called on each retry with attempt number.
--- @return boolean  true if constraint satisfied, false if retries exhausted.
---
--- @usage
---   bt:checkpoint("sql_table")
---   bt:forward(function(p) return p:find("%s") end)  -- generate table name
---   bt:constrain("sql_table", function(text)
---       local tname = text:match("FROM%s+(%w+)")
---       return tname and db_schema:has_table(tname)
---   end)
function Backtrack:constrain(symbol, validator, opts)
    opts = opts or {}
    local max_retries = opts.max_retries or self._max_retries

    -- Check current state first
    if validator(self:text()) then return true end

    -- Constraint violated: backtrack and resample
    local checkpoints = self._symbols[symbol]
    if not checkpoints or #checkpoints == 0 then
        error("[ion7.grammar.backtrack] no checkpoint for symbol: " .. symbol)
    end
    local snap_idx = checkpoints[#checkpoints]

    for attempt = 1, max_retries do
        if opts.on_retry then pcall(opts.on_retry, attempt) end
        self:_restore_to(snap_idx)

        -- Let caller drive generation forward after restore
        -- (they call forward() again in their loop)
        -- Here we just resample one token to avoid identical output
        local tok, _ = self:_gen_one()
        if not tok then return false end

        if validator(self:text()) then return true end
    end

    return false  -- exhausted retries
end

--- Run a complete constrained generation loop with automatic backtracking.
---
--- High-level API that combines forward(), checkpoint(), and constrain()
--- into a single call. The grammar handles the loop, the caller provides
--- the validation logic per symbol.
---
--- @param  steps  table  Array of step descriptors:
---   { symbol, until_pred, validator, max_retries }
---   symbol       string     Checkpoint name.
---   until_pred   function?  fn(piece, text) → boolean. Stop forward at this.
---   validator    function?  fn(text) → boolean. Semantic constraint.
---   max_retries  number?    Per-step retry limit.
--- @return string   text  Full generated text.
--- @return boolean  ok    true if all constraints satisfied, false if any failed.
---
--- @usage
---   local text, ok = bt:run({
---       { symbol = "table_ref",
---         until_pred = function(p) return p:find("%s") end,
---         validator  = function(t) return db:has_table(t:match("%w+$")) end },
---       { symbol = "column_ref",
---         until_pred = function(p) return p:find(",") end,
---         validator  = function(t) return db:has_column(t:match("%w+$")) end },
---   })
function Backtrack:run(steps)
    local all_ok = true
    for _, step in ipairs(steps) do
        if self._done then break end

        -- Save checkpoint for this step
        self:checkpoint(step.symbol)

        -- Generate until predicate
        self:forward(step.until_pred, step.max_tokens)

        -- Apply semantic constraint if provided
        if step.validator then
            local ok = self:constrain(step.symbol, step.validator, {
                max_retries = step.max_retries,
            })
            if not ok then all_ok = false end
        end
    end
    return self:text(), all_ok
end

return Backtrack
