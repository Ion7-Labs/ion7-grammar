--- SPDX-License-Identifier: MIT
--- ion7-grammar — GrammarContext and DCCD runtime tests.
---
--- Run standalone:  luajit tests/spec/test_runtime.lua
--- Or via runner:   luajit tests/test_pure.lua
require "tests.helpers"

local T       = require "tests.framework"
local Grammar = require "ion7.grammar"
local DCCD_m  = require "ion7.grammar.runtime.dccd"

-- GrammarContext

T.suite("GrammarContext")

T.test("new: creates context with default root='root'", function()
    local gc = Grammar.context()
    T.eq(type(gc), "table")
    T.eq(gc._root, "root")
end)

T.test("new: custom root option", function()
    T.eq(Grammar.context({ root = "myroot" })._root, "myroot")
end)

T.test("learn_enum: updates stats, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_enum("status", { "ok", "error" })
    T.eq(ret, gc)
    T.eq(gc:stats().n_enums, 1)
end)

T.test("learn_enum: asserts string rule_name", function()
    T.err(function() Grammar.context():learn_enum(42, { "a" }) end)
end)

T.test("learn_enum: grammar compiles with enum rule", function()
    local gc = Grammar.context()
    gc:learn_enum("color", { "red", "green", "blue" })
    local gbnf = gc:current():to_gbnf()
    T.ok(gbnf:find('"red"') or gbnf:find('"green"'))
end)

T.test("learn_table: creates column rules", function()
    local gc = Grammar.context()
    gc:learn_table("users", { "id", "name", "email" })
    local gbnf = gc:current():to_gbnf()
    T.ok(gbnf:find("users") or gbnf:find("name"))
end)

T.test("learn_table: updates stats, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_table("orders", { "id", "amount" })
    T.eq(ret, gc)
    T.eq(gc:stats().n_tables, 1)
end)

T.test("learn_table: asserts string name", function()
    T.err(function() Grammar.context():learn_table(42, { "col" }) end)
end)

T.test("learn_tool: registers tool, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_tool("search", { type = "object" })
    T.eq(ret, gc)
    T.eq(gc:stats().n_tools, 1)
end)

T.test("learn_tool: replaces existing tool with same name", function()
    local gc = Grammar.context()
    gc:learn_tool("search", { type = "object" })
    gc:learn_tool("search", { type = "object", properties = { q = { type = "string" } } })
    T.eq(gc:stats().n_tools, 1)
end)

T.test("learn_rule: adds a custom rule, returns self", function()
    local gc = Grammar.context()
    local ret = gc:learn_rule("myroot", Grammar.plus(Grammar.char("a-z")))
    T.eq(ret, gc)
    T.eq(gc:stats().n_extra, 1)
end)

T.test("learn_rule: replaces rule with same name", function()
    local gc = Grammar.context()
    gc:learn_rule("r", Grammar.literal("a"))
    gc:learn_rule("r", Grammar.literal("b"))
    T.eq(gc:stats().n_extra, 1)
end)

T.test("forget: removes enum", function()
    local gc = Grammar.context()
    gc:learn_enum("status", { "ok" })
    gc:forget("status")
    T.eq(gc:stats().n_enums, 0)
end)

T.test("forget: removes table", function()
    local gc = Grammar.context()
    gc:learn_table("users", { "id" })
    gc:forget("users")
    T.eq(gc:stats().n_tables, 0)
end)

T.test("forget: removes tool", function()
    local gc = Grammar.context()
    gc:learn_tool("search")
    gc:forget("search")
    T.eq(gc:stats().n_tools, 0)
end)

T.test("forget: returns self for nonexistent name", function()
    local gc = Grammar.context()
    T.eq(gc:forget("nonexistent"), gc)
end)

T.test("current: returns Grammar_obj with to_gbnf", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    T.ok(type(gc:current().to_gbnf) == "function")
end)

T.test("current: caches result until invalidated", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    T.eq(gc:current(), gc:current())
end)

T.test("current: invalidated after learn_enum", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    local g1 = gc:current()
    gc:learn_enum("y", { "b" })
    T.neq(g1, gc:current())
end)

T.test("current: empty context produces compilable grammar", function()
    T.no_error(function() Grammar.context():current():to_gbnf() end)
end)

T.test("snapshot: captures current state", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    local snap = gc:snapshot()
    T.eq(type(snap), "table")
    T.ok(snap.enums ~= nil)
    T.ok(snap.enums["x"] ~= nil)
end)

T.test("restore: reverts to snapshotted state", function()
    local gc = Grammar.context()
    gc:learn_enum("x", { "a" })
    local snap = gc:snapshot()
    gc:learn_enum("y", { "b" })
    T.eq(gc:stats().n_enums, 2)
    gc:restore(snap)
    T.eq(gc:stats().n_enums, 1)
    T.ok(gc._enums["x"] ~= nil)
    T.ok(gc._enums["y"] == nil)
end)

T.test("restore: reverts tools", function()
    local gc = Grammar.context()
    gc:learn_tool("t1")
    local snap = gc:snapshot()
    gc:learn_tool("t2")
    gc:restore(snap)
    T.eq(gc:stats().n_tools, 1)
end)

T.test("restore: returns self", function()
    local gc = Grammar.context()
    T.eq(gc:restore(gc:snapshot()), gc)
end)

T.test("stats: reports all counts", function()
    local gc = Grammar.context()
    gc:learn_enum("e", { "v" })
    gc:learn_table("t", { "c" })
    gc:learn_tool("tool")
    gc:learn_rule("r", Grammar.literal("x"))
    local s = gc:stats()
    T.eq(s.n_enums,  1)
    T.eq(s.n_tables, 1)
    T.eq(s.n_tools,  1)
    T.eq(s.n_extra,  1)
end)

T.test("to_gbnf on current: compiles multiple enums", function()
    local gc = Grammar.context()
    gc:learn_enum("color", { "red", "blue" })
    gc:learn_enum("size",  { "small", "large" })
    T.ok(type(gc:current():to_gbnf()) == "string")
end)

-- DCCD mock helpers (shared across DCCD suites)

local function make_scripted_sampler(token_seq, eog_id)
    local idx = 0
    return {
        reset  = function() idx = 0 end,
        sample = function(_, _, _)
            idx = idx + 1
            if idx > #token_seq then return eog_id end
            return token_seq[idx]
        end,
        accept = function() end,
    }
end

local TOKEN_PIECES = {
    [1] = "{",  [2] = '"', [3] = "s",   [4] = "t",  [5] = "a",
    [6] = "t",  [7] = "u", [8] = "s",   [9] = '"',  [10] = ":",
    [11] = '"', [12] = "o", [13] = "k", [14] = '"', [15] = "}",
    [20] = "I", [21] = " ", [22] = "t", [23] = "h",
    [24] = "i", [25] = "n", [26] = "k",
}
local EOG_ID = 999

local mock_vocab = {
    is_eog   = function(_, tok) return tok == EOG_ID end,
    piece    = function(_, tok) return TOKEN_PIECES[tok] or "?" end,
    -- tokenize: each byte becomes one token (id = byte value), 0-indexed array
    tokenize = function(_, str, _, _)
        local toks = {}
        for i = 0, #str - 1 do toks[i] = str:byte(i + 1) end
        return toks, #str
    end,
}

local snap_id = 0
local mock_ctx = {
    _n_past = 10,
    ptr     = function(self) return self end,
    n_past       = function(self) return self._n_past end,
    set_n_past   = function(self, n) self._n_past = n end,
    decode_single = function(self, _, _) self._n_past = self._n_past + 1 end,
    seq_snapshot = function(self, _seq)
        snap_id = snap_id + 1
        return { id = snap_id, n_past = self._n_past }
    end,
    seq_restore = function(self, snap, _seq) self._n_past = snap.n_past end,
}

local draft_seq = { 20, 21, 22, 23, 24, 25, 26 }
local final_seq = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

-- DCCD mock

T.suite("DCCD mock")

T.test("DCCD.new: returns DCCD instance with generate function", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(type(dc), "table")
    T.ok(type(dc.generate) == "function")
end)

T.test("DCCD.new: opts stored correctly (max_d, max_f, best_k)", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 64,
        max_final_tokens  = 128,
        best_of_k         = 2,
    })
    T.eq(dc._max_d, 64)
    T.eq(dc._max_f, 128)
    T.eq(dc._best_k, 2)
end)

T.test("DCCD.new: defaults: max_d=512, max_f=512, best_k=1", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(dc._max_d, 512)
    T.eq(dc._max_f, 512)
    T.eq(dc._best_k, 1)
end)

T.test("DCCD.new: asserts ctx required", function()
    T.err(function()
        DCCD_m.new(nil, mock_vocab, { draft_sampler = {}, constrain_sampler = {} })
    end, "ctx required")
end)

T.test("DCCD.new: asserts vocab required", function()
    T.err(function()
        DCCD_m.new(mock_ctx, nil, { draft_sampler = {}, constrain_sampler = {} })
    end, "vocab required")
end)

T.test("DCCD.new: asserts draft_sampler required", function()
    T.err(function()
        DCCD_m.new(mock_ctx, mock_vocab, { constrain_sampler = {} })
    end, "draft_sampler required")
end)

T.test("DCCD.new: asserts constrain_sampler required", function()
    T.err(function()
        DCCD_m.new(mock_ctx, mock_vocab, { draft_sampler = {} })
    end, "constrain_sampler required")
end)

T.test("generate: returns result table with all expected fields", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 32,
        max_final_tokens  = 32,
    })
    local result = dc:generate()
    T.eq(type(result), "table")
    T.eq(type(result.text),         "string")
    T.eq(type(result.draft),        "string")
    T.eq(type(result.tokens),       "table")
    T.eq(type(result.draft_tokens), "table")
    T.eq(type(result.n_tokens),     "number")
    T.eq(type(result.n_draft_toks), "number")
end)

T.test("generate: final text matches scripted sequence", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 32,
        max_final_tokens  = 32,
    })
    T.eq(dc:generate().text, '{"status":"ok"}')
end)

T.test("generate: draft text matches scripted draft", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(dc:generate().draft, "I think")
end)

T.test("generate: calls ctx:seq_snapshot() at least once", function()
    mock_ctx._n_past = 10
    local before = snap_id
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    dc:generate()
    T.ok(snap_id > before)
end)

T.test("generate: n_tokens == #tokens", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    local r = dc:generate()
    T.eq(r.n_tokens, #r.tokens)
end)

T.test("generate: n_draft_toks == #draft_tokens", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    local r = dc:generate()
    T.eq(r.n_draft_toks, #r.draft_tokens)
end)

T.test("generate: draft tokens injected into KV (arXiv:2603.03305 §3)", function()
    local kv_injected = {}
    local mock_ctx_instr = {
        _n_past = 10,
        ptr = function(self) return self end,
        n_past       = function(self) return self._n_past end,
        set_n_past   = function(self, n) self._n_past = n end,
        decode_single = function(self, tok, _)
            self._n_past = self._n_past + 1
            kv_injected[#kv_injected + 1] = tok
        end,
        seq_snapshot = function(self, _seq) return { n_past = self._n_past } end,
        seq_restore  = function(self, snap, _seq)
            self._n_past = snap.n_past
            kv_injected = {}   -- reset on restore: only care about post-restore calls
        end,
    }

    local dc_instr = DCCD_m.new(mock_ctx_instr, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20, 21 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1, 2, 3 }, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 10,
    })

    dc_instr:generate()

    -- After last restore: [20, 21] (draft injection) then [1, 2, 3] (constrained)
    T.eq(#kv_injected, 5, "draft+final = 5 tokens in KV (got " .. #kv_injected .. ")")
    T.eq(kv_injected[1], 20, "draft token 1 = 20")
    T.eq(kv_injected[2], 21, "draft token 2 = 21")
    T.eq(kv_injected[3],  1, "constrained token 1 = 1")
    T.eq(kv_injected[4],  2, "constrained token 2 = 2")
    T.eq(kv_injected[5],  3, "constrained token 3 = 3")
end)

T.test("on_draft_token: fires for draft pieces (k=1)", function()
    mock_ctx._n_past = 10
    local draft_cb = {}
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        on_draft_token    = function(p) draft_cb[#draft_cb + 1] = p end,
    })
    dc:generate()
    T.ok(#draft_cb > 0)
end)

T.test("on_final_token: fires and pieces concatenate to expected text", function()
    mock_ctx._n_past = 10
    local final_cb = {}
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        on_final_token    = function(p) final_cb[#final_cb + 1] = p end,
    })
    dc:generate()
    T.ok(#final_cb > 0)
    T.eq(table.concat(final_cb), '{"status":"ok"}')
end)

T.test("best_of: returns result table", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    local r = dc:best_of(2)
    T.eq(type(r), "table")
    T.ok(type(r.text) == "string")
end)

T.test("best_of k=3: selects longest constrained output", function()
    local calls = 0
    local draft_lengths = { 2, 5, 3 }
    local function make_variable_draft()
        return {
            reset  = function() end,
            accept = function() end,
            sample = function(_, _, _)
                calls = calls + 1
                local attempt = math.ceil(calls / 10)
                attempt = math.max(1, math.min(3, attempt))
                local len = draft_lengths[attempt] or 2
                local pos = ((calls - 1) % 10) + 1
                if pos > len then return EOG_ID end
                return 20 + pos
            end,
        }
    end

    mock_ctx._n_past = 10
    calls = 0
    local dc2 = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_variable_draft(),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 32,
        best_of_k         = 3,
    })
    local r2 = dc2:generate()
    T.ok(type(r2.text) == "string")
    T.ok(#r2.draft_tokens >= 2)
end)

T.test("Grammar.dccd: returns DCCD instance with generate/best_of", function()
    mock_ctx._n_past = 10
    local dc = Grammar.dccd(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(type(dc), "table")
    T.ok(type(dc.generate) == "function")
    T.ok(type(dc.best_of)  == "function")
end)

T.test("Grammar.dccd: default max_draft_tokens=512", function()
    mock_ctx._n_past = 10
    local dc = Grammar.dccd(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(dc._max_d, 512)
end)

-- DCCD spec_draft_fn path

T.suite("DCCD spec_draft_fn path")

T.test("DCCD.new: spec_draft_fn accepted without draft_sampler", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        spec_draft_fn     = function(_) return { 20, 21, 22 } end,
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
    })
    T.eq(type(dc), "table")
    T.ok(type(dc.generate) == "function")
end)

T.test("DCCD.new: spec_draft_fn is called during generate", function()
    mock_ctx._n_past = 10
    local called = false
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        spec_draft_fn     = function(_) called = true; return { 20, 21 } end,
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_final_tokens  = 10,
    })
    dc:generate()
    T.ok(called, "spec_draft_fn should be called during generate")
end)

T.test("DCCD.new: still requires constrain_sampler when spec_draft_fn provided", function()
    T.err(function()
        DCCD_m.new(mock_ctx, mock_vocab, {
            spec_draft_fn = function(_) return {} end,
        })
    end, "constrain_sampler required")
end)

T.test("DCCD.new: still errors when neither draft_sampler nor spec_draft_fn given", function()
    T.err(function()
        DCCD_m.new(mock_ctx, mock_vocab, {
            constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        })
    end, "draft_sampler required")
end)

T.test("generate: spec_draft_fn tokens injected before constrained pass", function()
    mock_ctx._n_past = 10
    local spec_toks_given = { 20, 21, 22 }
    local kv_spec = {}
    local mock_ctx_spec = {
        _n_past  = 10,
        _last_tok = 7,
        ptr      = function(self) return self end,
        n_past       = function(self) return self._n_past end,
        set_n_past   = function(self, n) self._n_past = n end,
        decode_single = function(self, tok, _)
            self._n_past = self._n_past + 1
            kv_spec[#kv_spec + 1] = tok
        end,
        seq_snapshot = function(self, _seq)
            return { n_past = self._n_past }
        end,
        seq_restore  = function(self, snap, _seq)
            self._n_past = snap.n_past
            kv_spec = {}
        end,
    }
    local dc = DCCD_m.new(mock_ctx_spec, mock_vocab, {
        spec_draft_fn     = function(_) return spec_toks_given end,
        constrain_sampler = make_scripted_sampler({ 1, 2, 3 }, EOG_ID),
        max_final_tokens  = 10,
    })
    local r = dc:generate()
    assert(r, "generate must return a result table")
    T.ok(type(r.draft) == "string")
    local dt = r.draft_tokens
    assert(dt, "draft_tokens must be present")
    T.eq(#dt, 3, "draft_tokens should be the spec tokens")
    T.eq(dt[1], 20)
    T.eq(dt[2], 21)
    T.eq(dt[3], 22)
end)

T.test("generate: spec_draft_fn empty → falls back to constrain_sampler draft", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        spec_draft_fn     = function(_) return {} end,
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 32,
    })
    local r = dc:generate()
    assert(r, "generate must return a result table")
    T.ok(type(r.text) == "string")
end)

T.test("generate: spec_draft_fn nil result treated as empty", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        spec_draft_fn     = function(_) return nil end,
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 32,
    })
    local r = dc:generate()
    T.eq(type(r), "table")
end)

-- DCCD close_thinking

T.suite("DCCD close_thinking")

T.test("close_thinking=true → n_close_toks = len('\\n</think>\\n')", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1 }, EOG_ID),
        max_draft_tokens  = 5,
        max_final_tokens  = 5,
        close_thinking    = true,
    })
    local r = dc:generate()
    assert(r)
    T.eq(r.n_close_toks, #"\n</think>\n")
end)

T.test("close_thinking=string → n_close_toks = len of custom string", function()
    mock_ctx._n_past = 10
    local close_str = "</think>"
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1 }, EOG_ID),
        max_draft_tokens  = 5,
        max_final_tokens  = 5,
        close_thinking    = close_str,
    })
    local r = dc:generate()
    assert(r)
    T.eq(r.n_close_toks, #close_str)
end)

T.test("close_thinking=false → n_close_toks = 0", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1 }, EOG_ID),
        max_draft_tokens  = 5,
        max_final_tokens  = 5,
        close_thinking    = false,
    })
    local r = dc:generate()
    assert(r)
    T.eq(r.n_close_toks, 0)
end)

T.test("close_thinking absent → n_close_toks = 0", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1 }, EOG_ID),
        max_draft_tokens  = 5,
        max_final_tokens  = 5,
    })
    local r = dc:generate()
    assert(r)
    T.eq(r.n_close_toks, 0)
end)

T.test("n_close_toks=0 when close_thinking not set", function()
    mock_ctx._n_past = 10
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 32,
    })
    local r = dc:generate()
    assert(r, "generate must return a result")
    T.eq(r.n_close_toks, 0)
end)

T.test("n_close_toks matches byte length of close sequence", function()
    mock_ctx._n_past = 10
    local close_str = "</think>"   -- 8 bytes → 8 mock tokens
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler(draft_seq, EOG_ID),
        constrain_sampler = make_scripted_sampler(final_seq, EOG_ID),
        max_draft_tokens  = 10,
        max_final_tokens  = 32,
        close_thinking    = close_str,
    })
    local r = dc:generate()
    assert(r, "generate must return a result")
    T.eq(r.n_close_toks, #close_str)
end)

T.test("n_past advances by n_close_toks extra when close_thinking set", function()
    mock_ctx._n_past = 10
    local pre_past = mock_ctx._n_past
    local close_str = "X"   -- 1 byte
    local dc = DCCD_m.new(mock_ctx, mock_vocab, {
        draft_sampler     = make_scripted_sampler({ 20 }, EOG_ID),
        constrain_sampler = make_scripted_sampler({ 1 }, EOG_ID),
        max_draft_tokens  = 5,
        max_final_tokens  = 5,
        close_thinking    = close_str,
    })
    local r = dc:generate()
    assert(r, "generate must return a result")
    -- n_past = pre + draft(1) + close(1) + final(1)
    T.eq(mock_ctx._n_past, pre_past + r.n_draft_toks + r.n_close_toks + r.n_tokens)
end)

local ok = T.summary()
os.exit(ok and 0 or 1)
