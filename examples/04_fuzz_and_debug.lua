--- examples/04_fuzz_and_debug.lua
--- ion7-grammar - Grammar fuzzing and debugging tools.
---
--- The fuzzer generates random valid strings from a grammar without using
--- a model. This lets you validate grammar correctness before spending GPU
--- time. The debug tools give structural insight into your grammars.
---
--- Use cases:
---   - Verify that your grammar accepts the strings you expect
---   - Catch over-constrained grammars (all samples are empty)
---   - Inspect rule dependencies and spot unreachable rules
---   - Diff two grammar versions to understand what changed
---
--- Run:
---   luajit examples/04_fuzz_and_debug.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grammar = require "ion7.grammar"

local function section(title)
    io.write("\n── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

io.write("══ ion7-grammar fuzz & debug ════════════════════════════════\n")

-- ── 1. Basic fuzzing ──────────────────────────────────────────────────────────
section("Grammar.fuzz - random valid strings")

--- fuzz(grammar, opts) returns { samples }, seed
--- opts.count     number of samples (default: 5)
--- opts.seed      RNG seed for reproducibility (default: random)
--- opts.max_rep   max repetitions for * and + (default: 4)
--- opts.max_depth recursion depth limit (default: 20)

--- Enum: always one of the listed values.
local color = Grammar.from_enum("root", { "red", "green", "blue", "yellow" })
local samples, seed = Grammar.fuzz(color, { count = 8, seed = 42 })
io.write("  color (seed=" .. seed .. "): " .. table.concat(samples, " | ") .. "\n")

--- Same seed → same output (reproducible).
local samples2 = Grammar.fuzz(color, { count = 8, seed = 42 })
assert(table.concat(samples) == table.concat(samples2), "reproducibility broken")
io.write("  reproducible: ✓\n")

--- Regex: generates strings matching the pattern.
local date = Grammar.from_regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
io.write("  date regex: ")
io.write(table.concat(Grammar.fuzz(date, { count = 4, seed = 1 }), " | ") .. "\n")

--- JSON Schema: generates valid JSON.
local schema = Grammar.from_json_schema({
    type = "object",
    properties = {
        id     = { type = "integer" },
        active = { type = "boolean" },
    },
    required = { "id", "active" },
    additionalProperties = false,
})
io.write("  JSON object: ")
io.write(table.concat(Grammar.fuzz(schema, { count = 2, seed = 3, max_rep = 2 }), "  |  ") .. "\n")

-- ── 2. fuzz_one ───────────────────────────────────────────────────────────────
section("Grammar.fuzz_one - single sample")

--- Convenience: generate exactly one random valid string.
local method = Grammar.from_enum("root", { "GET", "POST", "PUT", "DELETE" })
for i = 1, 5 do
    io.write("  fuzz_one: " .. Grammar.fuzz_one(method) .. "\n")
end

-- ── 3. fuzz_validate ──────────────────────────────────────────────────────────
section("Grammar.fuzz_validate - grammar health check")

--- fuzz_validate returns true if the grammar produces non-empty strings.
--- Use before passing a grammar to the model - catch bugs early.

--- Good grammar: always valid.
local good = Grammar.from_enum("root", { "a", "b", "c" })
local ok, err = Grammar.fuzz_validate(good, { count = 20, seed = 1 })
io.write("  enum grammar valid: " .. tostring(ok) .. "\n")

--- Complex grammar: JSON schema with constraints.
local complex = Grammar.from_json_schema({
    type = "object",
    properties = { name = { type = "string", minLength = 1 } },
    required = { "name" },
    additionalProperties = false,
})
ok, err = Grammar.fuzz_validate(complex, { count = 10, seed = 2 })
io.write("  JSON schema valid: " .. tostring(ok) .. "\n")

--- Validate before any model call (good practice).
local function safe_generate(grammar_obj, prompt)
    local valid, error_msg = Grammar.fuzz_validate(grammar_obj, { count = 10 })
    if not valid then
        io.write("  [WARNING] grammar issue: " .. tostring(error_msg) .. "\n")
        return nil
    end
    io.write("  grammar pre-validated ✓, would call model with: " .. prompt .. "\n")
    return grammar_obj:to_gbnf()
end

safe_generate(good, "What color?")
safe_generate(complex, "Return user data as JSON.")

-- ── 4. Grammar.debug ──────────────────────────────────────────────────────────
section("Grammar.debug - annotated GBNF with rule stats")

--- debug(g) returns a human-readable representation with stats.
local g = Grammar.from_json_schema({
    type = "object",
    properties = {
        status  = { enum = { "active", "inactive" } },
        count   = { type = "integer" },
    },
    required = { "status" },
    additionalProperties = false,
})
io.write(Grammar.debug(g) .. "\n")

-- ── 5. Grammar.analyze ────────────────────────────────────────────────────────
section("Grammar.analyze - structural analysis")

--- analyze returns: n_rules, root, unreferenced, recursive, gbnf_length
local analysis = Grammar.analyze(g)
io.write(string.format("  rules:        %d\n", analysis.n_rules))
io.write(string.format("  root:         %s\n", analysis.root))
io.write(string.format("  GBNF size:    %d bytes\n", analysis.gbnf_length))
if #analysis.unreferenced > 0 then
    io.write("  unreferenced: " .. table.concat(analysis.unreferenced, ", ") .. "\n")
end
if #analysis.recursive > 0 then
    io.write("  recursive:    " .. table.concat(analysis.recursive, ", ") .. "\n")
end

-- ── 6. Grammar.tree ───────────────────────────────────────────────────────────
section("Grammar.tree - rule dependency tree")

io.write(Grammar.tree(g) .. "\n")

-- ── 7. Grammar.diff ───────────────────────────────────────────────────────────
section("Grammar.diff - compare two grammars")

--- Version 1: basic user.
local user_v1 = Grammar.from_json_schema({
    type = "object",
    properties = { name = { type = "string" }, age = { type = "integer" } },
    required = { "name" },
    additionalProperties = false,
})

--- Version 2: added email, removed age, added role.
local user_v2 = Grammar.from_json_schema({
    type = "object",
    properties = {
        name  = { type = "string" },
        email = { type = "string" },
        role  = { enum = { "admin", "user", "guest" } },
    },
    required = { "name", "email" },
    additionalProperties = false,
})

io.write(Grammar.diff(user_v1, user_v2) .. "\n")

-- ── 8. Fuzz as a test suite ───────────────────────────────────────────────────
section("Fuzz as a lightweight test suite")

--- Run this before every deploy to catch grammar regressions.
local function test_grammar(name, grammar, validator, opts)
    opts = opts or {}
    local samples = Grammar.fuzz(grammar, { count = opts.count or 20, seed = opts.seed or 42 })
    local pass, fail = 0, 0
    local failures = {}
    for _, s in ipairs(samples) do
        if validator(s) then
            pass = pass + 1
        else
            fail = fail + 1
            failures[#failures + 1] = s
        end
    end
    local status = fail == 0 and "[PASS]" or "[FAIL]"
    io.write(string.format("  %s %-20s  %d/%d valid\n", status, name, pass, pass + fail))
    if #failures > 0 then
        io.write("         failures: " .. table.concat(failures, ", ") .. "\n")
    end
    return fail == 0
end

--- Test: enum values are always in the allowed set.
local valid_colors = { red = true, green = true, blue = true, yellow = true }
test_grammar("color enum", color,
    function(s) return valid_colors[s] == true end)

--- Test: date format is YYYY-MM-DD (10 chars, correct pattern).
test_grammar("ISO date", date,
    function(s)
        return #s == 10 and s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
    end)

--- Test: HTTP methods are uppercase ASCII.
test_grammar("HTTP method", method,
    function(s) return s:match("^[A-Z]+$") ~= nil end)

io.write("\n══ done ═══════════════════════════════════════════════════════\n")
io.write("Tip: run fuzz_validate() before every model call to catch grammar bugs early.\n")
