--- examples/01_basics.lua
--- ion7-grammar - Basics: every constructor, run without a model.
---
--- Demonstrates Grammar.from_enum, from_regex, from_type, from_json_schema,
--- and from_builder. Compiles grammars and prints the resulting GBNF.
--- No model required - use Grammar.fuzz() to verify output.
---
--- Run:
---   cd ~/Projets/LLM/ion7-grammar
---   luajit examples/01_basics.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grammar = require "ion7.grammar"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function section(title)
    io.write("\n── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

local function show(name, g, sample_count)
    io.write(string.format("  %-24s  %s\n", name .. ":", g:to_gbnf():gsub("\n", " ↵ ")))
    if sample_count then
        local samples = Grammar.fuzz(g, { count = sample_count, seed = 1 })
        io.write("  samples: " .. table.concat(samples, " | ") .. "\n")
    end
end

io.write("══ ion7-grammar basics ═══════════════════════════════════════\n")

-- ── 1. from_enum ──────────────────────────────────────────────────────────────
-- Constrain output to an exact whitelist of values.
-- Longest values are tried first to avoid prefix ambiguity.
section("from_enum")

--- Sentiment classifier: only "positive", "negative", or "neutral" allowed.
local sentiment = Grammar.from_enum("root", { "positive", "negative", "neutral" })
show("sentiment", sentiment, 5)

--- HTTP method whitelist.
local method = Grammar.from_enum("root", { "GET", "POST", "PUT", "DELETE", "PATCH" })
show("http_method", method, 5)

--- Boolean literals (Lua-style).
local bool_g = Grammar.from_enum("root", { "true", "false" })
show("boolean", bool_g, 4)

-- ── 2. from_json_enum ─────────────────────────────────────────────────────────
-- Like from_enum but wraps values in JSON string quotes.
-- Use for JSON field values that must come from a fixed set.
section("from_json_enum")

--- JSON-quoted status field.
local status_json = Grammar.from_json_enum("root", { "ok", "error", "pending" })
show("json_status", status_json, 3)

-- ── 3. from_regex ─────────────────────────────────────────────────────────────
-- Convert an ERE regex to a grammar. The model cannot deviate from the pattern.
-- Supported: . [] [^] \d\w\s * + ? {n} {n,m} () |
section("from_regex")

--- ISO date: YYYY-MM-DD only.
local date = Grammar.from_regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
show("iso_date", date, 3)

--- UUID v4 format (simplified).
local uuid = Grammar.from_regex(
    "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
show("uuid_v4", uuid, 2)

--- Semantic version: e.g. "1.2.3".
local semver = Grammar.from_regex("[0-9]+\\.[0-9]+\\.[0-9]+")
show("semver", semver, 4)

--- Simple email (structural, not RFC-complete).
local email = Grammar.from_regex("[a-z0-9]+@[a-z0-9]+\\.[a-z]{2,4}")
show("email", email, 3)

--- Hex color code.
local hex_color = Grammar.from_regex("#[0-9a-fA-F]{6}")
show("hex_color", hex_color, 4)

-- ── 4. from_type ──────────────────────────────────────────────────────────────
-- Shortest path to a grammar: Lua type annotations → GBNF.
-- No JSON Schema knowledge required.
--
-- Syntax:
--   "string"      → any JSON string
--   "integer"     → any JSON integer
--   "number"      → any JSON number
--   "boolean"     → true | false
--   "null"        → null
--   "any"         → any JSON value
--   "type?"       → optional (null or type)
--   { "type" }    → array of that type
--   { k = "type"} → object (all fields required by default)
--   { ["k?"] = t} → object with optional field k
section("from_type")

--- Simple object: name + age required, score optional.
local person = Grammar.from_type({
    name        = "string",
    age         = "integer",
    ["score?"]  = "number",
})
show("person", person)

--- API response with nested array.
local api_resp = Grammar.from_type({
    status  = "string",
    count   = "integer",
    items   = { "string" },
})
show("api_response", api_resp)

--- Array of booleans.
local flags = Grammar.from_type({ "boolean" })
show("bool_array", flags)

-- ── 5. from_json_schema ───────────────────────────────────────────────────────
-- Full JSON Schema draft-07 support.
-- Supports: type, properties, required, additionalProperties, items,
-- minItems, maxItems, enum, const, oneOf, anyOf, $ref, $defs, minLength,
-- maxLength, pattern.
section("from_json_schema")

--- Object with enum field and pattern-constrained string.
local product = Grammar.from_json_schema({
    type = "object",
    properties = {
        id       = { type = "string", pattern = "^PRD-[0-9]{4}$" },
        name     = { type = "string", minLength = 1, maxLength = 64 },
        category = { enum = { "electronics", "clothing", "food", "other" } },
        price    = { type = "number" },
        in_stock = { type = "boolean" },
    },
    required = { "id", "name", "category", "price" },
    additionalProperties = false,
})
show("product", product)

--- oneOf: either a string or null.
local nullable_str = Grammar.from_json_schema({
    oneOf = { { type = "string" }, { type = "null" } }
})
show("nullable_string", nullable_str)

--- Array of integers with bounds.
local int_array = Grammar.from_json_schema({
    type     = "array",
    items    = { type = "integer" },
    minItems = 1,
    maxItems = 5,
})
show("int_array_1_5", int_array)

-- ── 6. from_builder ───────────────────────────────────────────────────────────
-- Full manual control. Define rules directly with AST primitives.
-- Use when the other constructors are too restrictive.
section("from_builder (manual)")

--- CSV line: comma-separated integers.
local csv_ints = Grammar.builder()
    :rule("root", Grammar.seq(
        Grammar.ref("integer"),
        Grammar.star(Grammar.seq(
            Grammar.literal(","),
            Grammar.ref("integer")
        ))
    ))
    :rule("integer", Grammar.seq(
        Grammar.opt(Grammar.literal("-")),
        Grammar.plus(Grammar.DIGIT)
    ))

show("csv_integers", Grammar.from_builder(csv_ints), 4)

--- Key=value pair (config file style).
local kv_pair = Grammar.builder()
    :rule("root", Grammar.seq(
        Grammar.ref("key"),
        Grammar.literal("="),
        Grammar.ref("value")
    ))
    :rule("key",   Grammar.plus(Grammar.char("a-zA-Z0-9_-")))
    :rule("value", Grammar.plus(Grammar.char("a-zA-Z0-9_./-")))

show("key_value", Grammar.from_builder(kv_pair), 4)

-- ── 7. raw passthrough ────────────────────────────────────────────────────────
-- Escape hatch: pass hand-written GBNF directly.
section("raw GBNF passthrough")

local raw = Grammar.raw(
    'root  ::= "yes" | "no" | "maybe"\n'
)
show("raw_gbnf", raw)

-- ── Summary ───────────────────────────────────────────────────────────────────
io.write("\n══ done ═══════════════════════════════════════════════════════\n")
io.write("All grammars compiled without a model.\n")
io.write("Use Grammar.fuzz(g, {count=N}) to generate random valid strings.\n")
io.write("Pass g:to_gbnf() to ion7-core Sampler.chain():grammar() for LLM use.\n")
