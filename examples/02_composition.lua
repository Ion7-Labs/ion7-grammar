--- examples/02_composition.lua
--- ion7-grammar - Grammar composition operators.
---
--- Grammars are composable like sets. This example shows every composition
--- operator: union, sequence, wrap, interleave, repeat_g, optional, annotate.
---
--- All composition operators return Grammar_obj, so they chain:
---   Grammar.wrap(Grammar.interleave(date, ","), "[", "]")
---
--- Run:
---   luajit examples/02_composition.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grammar = require "ion7.grammar"

local function section(title)
    io.write("\n── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

local function show(name, g, seed)
    local samples = Grammar.fuzz(g, { count = 4, seed = seed or 1, max_rep = 3 })
    io.write(string.format("  %-28s  %s\n", name .. ":", table.concat(samples, " | ")))
end

io.write("══ ion7-grammar composition ══════════════════════════════════\n")

-- ── Building blocks ───────────────────────────────────────────────────────────

--- Reusable grammar pieces used in composition examples below.
local digit     = Grammar.from_regex("[0-9]")
local lower     = Grammar.from_regex("[a-z]+")
local word      = Grammar.from_regex("[a-zA-Z]+")
local integer   = Grammar.from_regex("-?[0-9]+")
local iso_date  = Grammar.from_regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
local http_verb = Grammar.from_enum("root", { "GET", "POST", "PUT", "DELETE" })
local color     = Grammar.from_enum("root", { "red", "green", "blue", "yellow" })
local bool_g    = Grammar.from_enum("root", { "true", "false" })

-- ── union ─────────────────────────────────────────────────────────────────────
-- Match either grammar a or grammar b.
-- Rule bodies from both grammars are merged; each gets a namespaced alias.
section("Grammar.union / g:union(other)")

--- String or integer.
local str_or_int = Grammar.union(
    Grammar.from_json_schema({ type = "string" }),
    Grammar.from_json_schema({ type = "integer" })
)
show("string | integer", str_or_int)

--- HTTP verb or "ANY" wildcard.
local verb_or_any = Grammar.union(
    http_verb,
    Grammar.from_enum("root", { "ANY" })
)
show("verb | ANY", verb_or_any)

--- Fluent method syntax (equivalent).
local color_or_bool = color:union(bool_g)
show("color | bool (fluent)", color_or_bool)

-- ── sequence ──────────────────────────────────────────────────────────────────
-- Match grammar a followed immediately by grammar b.
-- An optional separator node can be placed between them.
section("Grammar.sequence / g:then_(other, sep)")

--- HTTP verb followed by a path segment: "GET /users"
local verb_path = Grammar.sequence(
    http_verb,
    Grammar.from_regex("/[a-z]+"),
    { separator = Grammar.literal(" ") }
)
show("verb + path", verb_path)

--- First name + last name (fluent).
local full_name = lower:then_(lower, Grammar.literal(" "))
show("first + last", full_name)

-- ── wrap ──────────────────────────────────────────────────────────────────────
-- Surround a grammar with prefix and suffix literals.
-- Optional whitespace is inserted between delimiters by default.
section("Grammar.wrap")

--- JSON array of colors: ["red", "blue", ...]
--- Step 1: a JSON-quoted color
local json_color = Grammar.from_json_enum("root", { "red", "green", "blue" })

--- Step 2: wrap in square brackets with optional whitespace
local color_arr = Grammar.wrap(json_color, "[", "]")
show("wrapped [color]", color_arr)

--- Parenthesised integer.
local paren_int = Grammar.wrap(integer, "(", ")", false)   -- false = no extra ws
show("(integer)", paren_int)

-- ── interleave ────────────────────────────────────────────────────────────────
-- Match grammar g separated by sep: g (sep g)*.
-- Perfect for comma-separated lists, pipe-delimited values, etc.
section("Grammar.interleave")

--- Comma-separated colors (1–4 elements).
local color_list = Grammar.interleave(color, ",", 1, 4)
show("color,color,...", color_list)

--- Pipe-separated HTTP verbs.
local verb_list = Grammar.interleave(http_verb, "|", 1, 3)
show("verb|verb|...", verb_list)

--- Space-separated words.
local words = Grammar.interleave(word, " ", 1, 5)
show("word word ...", words)

-- ── repeat_g ─────────────────────────────────────────────────────────────────
-- Repeat grammar g between min and max times, with optional separator.
section("Grammar.repeat_g")

--- Exactly 3 digits.
local three_digits = Grammar.repeat_g(digit, 3, 3)
show("digit x3", three_digits)

--- 1 to 4 colors with comma separator.
local multi_color = Grammar.repeat_g(color, 1, 4, Grammar.literal(","))
show("1-4 colors", multi_color)

-- ── optional ──────────────────────────────────────────────────────────────────
-- Match grammar g or the empty string (zero or one occurrence).
section("Grammar.optional")

--- Optional sign prefix for a number.
local signed = Grammar.sequence(
    Grammar.optional(Grammar.from_enum("root", { "+", "-" })),
    Grammar.from_regex("[0-9]+")
)
show("signed integer", signed)

-- ── annotate ──────────────────────────────────────────────────────────────────
-- Rename the root rule of a grammar for semantic clarity.
-- Useful when embedding grammars into larger compositions.
section("Grammar.annotate")

--- Annotate the date grammar with a semantic name.
local birth_date = Grammar.annotate(iso_date, "birth-date")
io.write("  birth_date rules: " .. table.concat(birth_date:rules(), ", ") .. "\n")

-- ── combining multiple operators ──────────────────────────────────────────────
-- Real-world patterns built by chaining composition operators.
section("Combined compositions")

--- JSON array of ISO dates: ["2026-01-01","2026-12-31",...]
local date_array = Grammar.wrap(
    Grammar.interleave(
        Grammar.from_json_enum("root", { "2026-04-01", "2026-06-15", "2026-12-31" }),
        ","
    ),
    "[", "]"
)
show("JSON date array", date_array)

--- CSV row: integers separated by commas, wrapped in optional quotes.
--- "1,2,3" or just 1,2,3
local csv_row = Grammar.interleave(integer, ",", 1, 5)
show("CSV integer row", csv_row)

--- HTTP request line: "GET /api/users HTTP/1.1"
local http_line = Grammar.sequence(
    Grammar.sequence(http_verb, Grammar.from_regex("/[a-z/]+"),
        { separator = Grammar.literal(" ") }),
    Grammar.from_enum("root", { "HTTP/1.0", "HTTP/1.1", "HTTP/2" }),
    { separator = Grammar.literal(" ") }
)
show("HTTP request line", http_line)

--- Color palette: 2–5 unique color names separated by " | "
local palette = Grammar.interleave(color, " | ", 2, 5)
show("color palette", palette)

-- ── merge ─────────────────────────────────────────────────────────────────────
-- Merge rules from another grammar into this one (non-destructive).
-- Rules from other are added only if not already defined.
section("Grammar_obj:merge()")

local base = Grammar.from_json_schema({
    type = "object",
    properties = { name = { type = "string" } },
    required   = { "name" },
})
local extended = Grammar.from_json_schema({
    type = "object",
    properties = {
        name  = { type = "string" },
        email = { type = "string", pattern = "[a-z]+@[a-z]+\\.[a-z]+" },
    },
    required = { "name", "email" },
})
-- extended has all rules from base plus its own extras
io.write("  base rules:     " .. #base:rules()     .. "\n")
io.write("  extended rules: " .. #extended:rules() .. "\n")

io.write("\n══ done ═══════════════════════════════════════════════════════\n")
