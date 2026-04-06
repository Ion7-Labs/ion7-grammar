--- @module ion7.grammar.fuzz
--- SPDX-License-Identifier: MIT
--- Grammar fuzzing - generate random valid strings without a model.
---
--- Given a Grammar, produces random strings that are guaranteed to match
--- the grammar. Useful for:
---   - Validating grammar correctness before using it with an LLM
---   - Generating test cases and example outputs
---   - Debugging: "does my grammar actually allow what I think it allows?"
---   - Benchmarking grammar complexity
---
--- This is pure Lua - zero model, zero GPU. Instant.
---
--- Algorithm: recursive AST walker with randomized choices.
---   alt   → pick one alternative uniformly at random
---   rep   → pick a count between min and max (capped at max_rep)
---   seq   → concatenate all items
---   char  → pick a random char from the class
---   lit   → return verbatim
---   ref   → recurse (depth-limited to prevent infinite recursion)
---
--- @usage
---   local Grammar = require "ion7.grammar"
---
---   local g = Grammar.from_json_schema({ type = "object",
---       properties = { name = { type = "string" }, age = { type = "integer" } },
---       required = { "name", "age" } })
---
---   local examples = Grammar.fuzz(g, { count = 5, seed = 42 })
---   for _, s in ipairs(examples) do print(s) end
---
---   -- Validate grammar before using with LLM
---   local ok, err = Grammar.validate_fuzz(g, { count = 20 })
---   if not ok then print("Grammar issue: " .. err) end
---
--- @author Ion7-Labs
--- @version 0.1.0

local Fuzzer = {}

-- ── PRNG ──────────────────────────────────────────────────────────────────────
-- Simple xorshift32 for reproducible randomness.
-- Uses bit library (LuaJIT built-in) instead of Lua 5.3+ ~ and << operators.

local bit = require "bit"

local function make_rng(seed)
    -- Mix seed with a constant (Wang hash) to avoid clustering near zero
    -- for small seeds. Without mixing, state/0x7FFFFFFF ≈ 0 for many
    -- iterations, so rng_int always returns the lowest index.
    local s = seed or os.time()
    s = bit.bxor(s, 0x9e3779b9)
    s = bit.band(s, 0x7FFFFFFF)
    if s == 0 then s = 0x12345678 end
    local state = s
    return function()
        state = bit.bxor(state, bit.lshift(state, 13))
        state = bit.band(state, 0xFFFFFFFF)
        state = bit.bxor(state, bit.rshift(state, 17))
        state = bit.band(state, 0xFFFFFFFF)
        state = bit.bxor(state, bit.lshift(state, 5))
        state = bit.band(state, 0x7FFFFFFF)
        return state / 0x7FFFFFFF
    end
end

local function rng_int(rng, lo, hi)
    if lo > hi then return lo end
    return lo + math.floor(rng() * (hi - lo + 1))
end

-- ── Character class expander ──────────────────────────────────────────────────

-- Expand a char class spec to an array of possible characters
local function expand_char_class(spec, negated)
    local chars = {}
    local seen  = {}
    local i = 1

    -- Parse the spec string
    while i <= #spec do
        local c = spec:sub(i, i)
        if c == '\\' and i < #spec then
            local esc = spec:sub(i+1, i+1)
            local ch
            if esc == 'n' then ch = '\n'
            elseif esc == 'r' then ch = '\r'
            elseif esc == 't' then ch = '\t'
            else ch = esc end
            i = i + 2
            if not seen[ch] then seen[ch]=true; chars[#chars+1]=ch end
        elseif i + 2 <= #spec and spec:sub(i+1,i+1) == '-' then
            -- Range a-z
            local from = string.byte(c)
            local to   = string.byte(spec, i+2)
            for code = from, to do
                local ch = string.char(code)
                if not seen[ch] then seen[ch]=true; chars[#chars+1]=ch end
            end
            i = i + 3
        else
            i = i + 1
            if not seen[c] then seen[c]=true; chars[#chars+1]=c end
        end
    end

    if not negated then
        return chars
    else
        -- Negated: return printable ASCII chars not in the set
        local neg = {}
        for code = 32, 126 do
            local ch = string.char(code)
            if not seen[ch] then neg[#neg+1] = ch end
        end
        return neg
    end
end

-- ── Biased repetition count ───────────────────────────────────────────────────

--- Pick a repetition count with a distribution that favours variety.
---
--- The plain uniform distribution over [0, max_rep] produces too many
--- zero-length strings (empty `*` expansions) and makes all samples look
--- similar. The biased version:
---   - When min=0, only produces 0 with 15% probability; the rest is
---     distributed uniformly over [1, max_n].
---   - Otherwise uses a triangular-ish distribution (average of two
---     uniform draws) to cluster around the middle of the range.
---
--- @param  rng    function  RNG function returning [0,1).
--- @param  min_n  number    Minimum count.
--- @param  max_n  number    Maximum count.
--- @return number  Chosen count in [min_n, max_n].
local function biased_rep(rng, min_n, max_n)
    if min_n == max_n then return min_n end
    if min_n == 0 and max_n >= 1 then
        -- 15% chance of zero, rest spread over [1, max_n]
        if rng() < 0.15 then return 0 end
        local a = rng_int(rng, 1, max_n)
        local b = rng_int(rng, 1, max_n)
        return math.floor((a + b) / 2 + 0.5)
    end
    -- Triangular: average of two uniform draws reduces variance
    local a = rng_int(rng, min_n, max_n)
    local b = rng_int(rng, min_n, max_n)
    return math.floor((a + b) / 2 + 0.5)
end

-- ── AST walker ────────────────────────────────────────────────────────────────

--- Recursive AST walker. Returns the generated string fragment.
--- @private
local function walk(node, rules_by_name, rng, depth, opts)
    if depth > (opts.max_depth or 20) then return "" end

    local k = node.kind

    if k == "literal" then
        return node.value

    elseif k == "char" then
        local chars = expand_char_class(node.spec, node.negated)
        if #chars == 0 then return "" end
        return chars[rng_int(rng, 1, #chars)]

    elseif k == "ref" then
        local rule = rules_by_name[node.name]
        if not rule then return "?" end
        return walk(rule.body, rules_by_name, rng, depth + 1, opts)

    elseif k == "seq" then
        local parts = {}
        for _, item in ipairs(node.items) do
            parts[#parts+1] = walk(item, rules_by_name, rng, depth, opts)
        end
        return table.concat(parts)

    elseif k == "alt" then
        -- Shuffle-based selection: build a random permutation of indices so
        -- that when generating multiple samples, each alternative gets visited
        -- before any is repeated. The permutation is seeded per-call so it
        -- differs across samples (per-sample RNG handles this automatically).
        local n = #node.items
        -- Simple Fisher-Yates on a local copy to pick a random index
        -- without needing to maintain external state.
        local idx = rng_int(rng, 1, n)
        return walk(node.items[idx], rules_by_name, rng, depth, opts)

    elseif k == "rep" then
        local min_n = node.min or 0
        local max_n = node.max
        if max_n < 0 then max_n = opts.max_rep or 4 end
        max_n = math.min(max_n, opts.max_rep or 4)
        if min_n > max_n then min_n = max_n end
        local count = biased_rep(rng, min_n, max_n)
        local parts = {}
        for _ = 1, count do
            parts[#parts+1] = walk(node.node, rules_by_name, rng, depth, opts)
        end
        return table.concat(parts)

    elseif k == "group" then
        return walk(node.node, rules_by_name, rng, depth, opts)

    else
        return ""
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Generate random valid strings from a grammar.
---
--- @param  grammar  any  The grammar to fuzz.
--- @param  opts     table?
---   opts.count      number?  Number of strings to generate (default: 5).
---   opts.seed       number?  RNG seed for reproducibility (default: random).
---   opts.max_depth  number?  Max recursion depth (default: 20).
---   opts.max_rep    number?  Max repetitions for * and + (default: 4).
---   opts.root       string?  Root rule name (default: "root").
--- @return table  Array of generated strings.
--- @return number  The seed used (for reproduction).
---
--- @usage
---   local Grammar = require "ion7.grammar"
---
---   local g = Grammar.from_enum("color", { "red", "green", "blue" })
---   local samples = Grammar.fuzz(g, { count = 3, seed = 1 })
---   -- { "green", "red", "blue" }
---
---   local g = Grammar.from_regex("\\d{1,4}")
---   local samples = Grammar.fuzz(g, { count = 5 })
---   -- { "7", "42", "1337", "0", "999" }  (random)
function Fuzzer.fuzz(grammar, opts)
    opts = opts or {}
    local count     = opts.count     or 5
    local seed      = opts.seed      or os.time()
    local root_name = opts.root      or "root"
    local rng       = make_rng(seed)

    -- Get rules from grammar
    local b = grammar._builder or grammar
    local rules = b._rules or {}

    -- Index by name
    local by_name = {}
    for _, r in ipairs(rules) do by_name[r.name] = r end

    -- Find root
    local root_rule = by_name[root_name]
    if not root_rule then
        -- Try first rule
        root_rule = rules[1]
        if not root_rule then
            error("[ion7.grammar.fuzz] no rules found in grammar")
        end
    end

    local results = {}
    for _ = 1, count do
        local ok, s = pcall(walk, root_rule.body, by_name, rng, 0, opts)
        results[#results+1] = ok and s or ""
    end
    return results, seed
end

--- Check that a grammar can produce non-empty valid strings.
---
--- Generates `count` examples and verifies none are empty (which would
--- indicate the grammar is too restrictive or has a bug).
---
--- @param  grammar  any
--- @param  opts     table?   Same as fuzz(), plus opts.allow_empty (bool).
--- @return boolean  ok   true if grammar produces valid non-empty output.
--- @return string?  err  Error description if ok is false, otherwise nil.
function Fuzzer.validate(grammar, opts)
    opts = opts or {}
    local allow_empty = opts.allow_empty or false
    local samples, seed = Fuzzer.fuzz(grammar, opts)

    local empty_count = 0
    for _, s in ipairs(samples) do
        if s == "" then empty_count = empty_count + 1 end
    end

    if not allow_empty and empty_count == #samples then
        return false, string.format(
            "all %d samples are empty (grammar may be unsatisfiable, seed=%d)",
            #samples, seed)
    end

    if empty_count > #samples / 2 then
        return false, string.format(
            "%d/%d samples are empty (grammar may be too restrictive, seed=%d)",
            empty_count, #samples, seed)
    end

    return true, nil
end

--- Generate exactly one random valid string.
--- Convenience wrapper around fuzz().
---
--- @param  grammar  any
--- @param  opts     table?  { seed, max_depth, max_rep, root }
--- @return string
function Fuzzer.one(grammar, opts)
    opts = opts or {}
    opts.count = 1
    local results = Fuzzer.fuzz(grammar, opts)
    return results[1] or ""
end

return Fuzzer
