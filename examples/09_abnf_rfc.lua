--- examples/09_abnf_rfc.lua
--- ion7-grammar — `Grammar.from_abnf` driven by a real RFC fragment.
---
--- Drops a verbatim slice of RFC 3339 (Date and Time on the Internet)
--- through `Grammar.from_abnf` and prints the resulting GBNF. Confirms
--- that grammars taken straight out of an IETF spec compile, fuzz, and
--- describe a usable shape — no rewriting required.
---
--- Run:
---   luajit examples/09_abnf_rfc.lua
---
--- @author Ion7-Labs

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Grammar = require "ion7.grammar"

local function section(title)
    io.write("\n── " .. title .. " " .. string.rep("─", 55 - #title) .. "\n")
end

-- ── 1. RFC 3339 date-time grammar ─────────────────────────────────────────────
-- Verbatim from §5.6 of RFC 3339, shortened to the fields the model
-- typically emits. ALPHA / DIGIT come from the RFC 5234 core rules and
-- are injected automatically by ion7-grammar.

local rfc3339 = Grammar.from_abnf([[
date-fullyear   = 4DIGIT
date-month      = 2DIGIT
date-mday       = 2DIGIT
time-hour       = 2DIGIT
time-minute     = 2DIGIT
time-second     = 2DIGIT
time-secfrac    = "." 1*DIGIT
time-numoffset  = ("+" / "-") time-hour ":" time-minute
time-offset     = "Z" / time-numoffset
partial-time    = time-hour ":" time-minute ":" time-second [ time-secfrac ]
full-date       = date-fullyear "-" date-month "-" date-mday
full-time       = partial-time time-offset
date-time       = full-date "T" full-time
]])

section("RFC 3339 date-time")
io.write(rfc3339:to_gbnf())
io.write("\n")

io.write("\n  fuzz samples (random valid strings):\n")
local samples = Grammar.fuzz(rfc3339, { count = 3, seed = 7 })
for _, s in ipairs(samples) do
    io.write("    " .. s .. "\n")
end

-- ── 2. URI scheme + authority excerpt (RFC 3986) ──────────────────────────────
-- A meaningful subset showing alternation (/) and grouping ([]).

local uri = Grammar.from_abnf([[
scheme       = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
ipv4         = octet "." octet "." octet "." octet
octet        = 1*3DIGIT
port         = 1*5DIGIT
authority    = ipv4 [ ":" port ]
absolute-uri = scheme "://" authority
]])

section("URI subset (RFC 3986)")
io.write(uri:to_gbnf())
io.write("\n")

io.write("\n  fuzz samples:\n")
for _, s in ipairs(Grammar.fuzz(uri, { count = 3, seed = 11 })) do
    io.write("    " .. s .. "\n")
end

-- ── 3. Pipeline shape ─────────────────────────────────────────────────────────

section("hand-off to ion7-core")
io.write([[
  local sampler = ion7.Sampler.chain()
      :grammar(rfc3339:to_gbnf(), "root", vocab)
      :greedy()
      :build()
  engine:chat(session, { sampler = sampler })
]])

io.write("\n══ done ════════════════════════════════════════════════════════\n")
