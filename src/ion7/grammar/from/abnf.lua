--- @module ion7.grammar.from.abnf
--- SPDX-License-Identifier: MIT
--- ABNF (RFC 5234) → GBNF converter.
---
--- Parses an ABNF rule list and produces an ion7 grammar Builder. RFC 5234
--- core rules (`ALPHA`, `DIGIT`, `HEXDIG`, `BIT`, `CR`, `LF`, `CRLF`,
--- `DQUOTE`, `HTAB`, `SP`, `WSP`, `VCHAR`, `CHAR`, `CTL`, `OCTET`) are
--- always available; redefine them in your input to override.
---
--- Supported syntax (RFC 5234 §4):
---   rulename = elements           Rule definition
---   "literal"                     Quoted string (case-sensitive — see notes)
---   %x41                          Hex char
---   %d65                          Decimal char
---   %b01000001                    Binary char
---   %x41-5A                       Hex range
---   %x48.65.6C.6C.6F              Concatenation of fixed bytes
---   element1 element2             Concatenation
---   element1 / element2           Alternation
---   2*4 element                   Between 2 and 4 repetitions
---   *element                      Zero or more
---   1*element                     One or more
---   3element                      Exactly three
---   [element]                     Optional
---   (element)                     Group
---   ; ...                         Comment to end of line
---
--- Differences from strict RFC 5234:
---   - Quoted strings are case-sensitive. Use `%x41` / `%x61` ranges to
---     express case-insensitive matches when needed.
---   - Incremental alternative (`rulename =/ ...`) is rejected.
---   - Prose values (`<...>`) are rejected.
---
--- @usage
---   local Grammar = require "ion7.grammar"
---   local g = Grammar.from_abnf([[
---       date = year "-" month "-" day
---       year = 4DIGIT
---       month = 2DIGIT
---       day = 2DIGIT
---   ]])
---   print(g:to_gbnf())
---
--- @author Ion7-Labs

local lpeg    = require "lpeg"
local ast     = require "ion7.grammar.ast"
local Builder = require "ion7.grammar.ast.builder"

local P, S, R, V    = lpeg.P, lpeg.S, lpeg.R, lpeg.V
local C, Cc, Ct, Cg = lpeg.C, lpeg.Cc, lpeg.Ct, lpeg.Cg

local table_unpack  = table.unpack or unpack
local table_concat  = table.concat
local string_char   = string.char
local string_format = string.format
local tonumber      = tonumber
local ipairs        = ipairs
local pairs         = pairs

-- ── Core rule bodies (RFC 5234 §B.1) ──────────────────────────────────────────

local function build_core_rules()
    return {
        ["alpha"]  = ast.char("A-Za-z"),
        ["digit"]  = ast.char("0-9"),
        ["hexdig"] = ast.char("0-9A-Fa-f"),
        ["bit"]    = ast.char("01"),
        ["cr"]     = ast.literal("\r"),
        ["lf"]     = ast.literal("\n"),
        ["crlf"]   = ast.seq(ast.literal("\r"), ast.literal("\n")),
        ["dquote"] = ast.literal('"'),
        ["htab"]   = ast.literal("\t"),
        ["sp"]     = ast.literal(" "),
        ["wsp"]    = ast.alt(ast.literal(" "), ast.literal("\t")),
        ["vchar"]  = ast.char("\\x21-\\x7e"),
        ["char"]   = ast.char("\\x01-\\x7f"),
        ["ctl"]    = ast.alt(ast.char("\\x00-\\x1f"), ast.literal("\\x7f")),
        ["octet"]  = ast.char("\\x00-\\xff"),
    }
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function alt_or_single(parts)
    if #parts == 1 then return parts[1] end
    return ast.alt(table_unpack(parts))
end

local function seq_or_single(parts)
    if #parts == 1 then return parts[1] end
    return ast.seq(table_unpack(parts))
end

--- A repetition prefix produces a `{ min, max }` pair consumed by apply_rep.
--- `min == max == nil` means "exactly one" — no rep wrapper needed.
local function apply_rep(rep, node)
    if rep == nil then return node end
    local lo, hi = rep[1], rep[2]
    if lo == 0 and hi == -1 then return ast.star(node) end
    if lo == 1 and hi == -1 then return ast.plus(node) end
    if lo == 0 and hi ==  1 then return ast.opt(node)  end
    return ast.rep(node, lo, hi)
end

local function literal_from_byte_concat(bytes)
    local chars = {}
    for i, b in ipairs(bytes) do chars[i] = string_char(b) end
    return ast.literal(table_concat(chars))
end

-- ── LPeg primitives ───────────────────────────────────────────────────────────

local digit  = R "09"
local alpha  = R("AZ", "az")
local hexdig = digit + R("AF", "af")
local sp     = P " " + P "\t"
local crlf   = P "\r"^-1 * P "\n"
local comment = P ";" * (P(1) - crlf)^0 * crlf
local c_nl   = comment + crlf
local c_wsp  = sp + (c_nl * sp)            -- "c-wsp" per RFC 5234 §4
local skip   = c_wsp^0                     -- "*c-wsp"
local skip1  = c_wsp^1                     -- "1*c-wsp"

-- ── Rule names normalised to lowercase ────────────────────────────────────────

local rulename = (C(alpha * (alpha + digit + P "-")^0)) / function(name)
    return name:lower()
end

-- ── Numeric values (%x41, %d65, %b01000001) ───────────────────────────────────

local function num_value(prefix, body_pat, base)
    -- Either: single digit run -> may chain with `.` (concat) or `-` (range)
    --         or just a single byte
    local digits_C = C(body_pat^1) / function(s) return tonumber(s, base) end
    return P(prefix) * (
        -- Concatenation: %x48.65.6C.6C.6F
        Ct(digits_C * (P "." * digits_C)^1) / literal_from_byte_concat
        -- Range: %x41-5A
      + (digits_C * P "-" * digits_C) / function(lo, hi)
            return ast.char(string_format("\\x%02x-\\x%02x", lo, hi))
        end
        -- Single value
      + digits_C / function(b)
            if b < 0x20 or b == 0x22 or b == 0x5c or b > 0x7e then
                return ast.char(string_format("\\x%02x", b))
            end
            return ast.literal(string_char(b))
        end
    )
end

local hex_val = num_value("x", hexdig, 16)
local dec_val = num_value("d", digit,  10)
local bin_val = num_value("b", S "01", 2)
local num_val = P "%" * (hex_val + dec_val + bin_val)

-- ── Quoted strings ────────────────────────────────────────────────────────────

local string_body = C((P(1) - P '"' - P "\r" - P "\n")^0)
local char_val = (P '"' * string_body * P '"') / function(s)
    return ast.literal(s)
end

-- ── Repetition prefix ─────────────────────────────────────────────────────────

local function digits_to_int(s) return tonumber(s) end

local repeat_prefix = (
        -- Two-bounded form: "*", "1*5", "2*", "*5", "0*", "1*"
        (C(digit^0) * P "*" * C(digit^0)) / function(lo, hi)
            return { lo == "" and 0 or digits_to_int(lo),
                     hi == "" and -1 or digits_to_int(hi) }
        end
        -- Exact count: "3"
      + (C(digit^1)) / function(n)
            local v = digits_to_int(n)
            return { v, v }
        end
    )

-- ── Defined-as ────────────────────────────────────────────────────────────────

-- We accept `=` and reject `=/` with a clear error.
local defined_as = skip * (
        P "=/" / function() error("[ion7.grammar.from.abnf] incremental alternatives (=/) are not supported") end
      + P "="
    ) * skip

-- ── Reject prose-val explicitly (we want a clear error, not silent skip) ──────

local prose_val = P "<" * (P(1) - P ">")^0 * P ">" / function()
    error("[ion7.grammar.from.abnf] prose values (<...>) are not supported")
end

-- ── Grammar ───────────────────────────────────────────────────────────────────

local abnf_grammar = P{ "rulelist",

    rulelist = Ct((V "rule" + skip * c_nl)^1) * skip * P(-1),

    rule = skip * Ct(rulename * defined_as * Cg(V "alternation", "body")) * skip * (c_nl + P(-1))
        / function(t) return { name = t[1], body = t.body } end,

    alternation = Ct(V "concat" * (skip * P "/" * skip * V "concat")^0)
        / alt_or_single,

    concat = Ct(V "rep_element" * (skip1 * V "rep_element")^0)
        / seq_or_single,

    rep_element = ((repeat_prefix + Cc(nil)) * V "element") / apply_rep,

    element = V "ref" + V "group" + V "option"
            + char_val + num_val + prose_val,

    ref = rulename / function(name) return ast.ref(name) end,

    group  = P "(" * skip * V "alternation" * skip * P ")",
    option = P "[" * skip * V "alternation" * skip * P "]"
           / function(node) return ast.opt(node) end,
}

-- ── Public API ────────────────────────────────────────────────────────────────

local function collect_refs(node, set)
    if not node then return end
    if node.kind == "ref" then set[node.name] = true; return end
    if node.items then
        for _, it in ipairs(node.items) do collect_refs(it, set) end
    elseif node.node then
        collect_refs(node.node, set)
    end
end

--- Parse an ABNF string into a Builder.
---
--- Only the core rules actually referenced by the user grammar are
--- emitted; unreferenced ones stay out of the compiled GBNF. User rules
--- with the same name as a core rule shadow the core entry.
---
--- @param  source  string   ABNF rulelist (RFC 5234 §4 syntax).
--- @param  root    string?  Root rule name (default: first defined rule).
--- @return Builder
local function from_abnf(source, root)
    -- Ensure trailing newline; ABNF requires CRLF after each rule.
    if not source:match("\n$") then source = source .. "\n" end

    local rules = abnf_grammar:match(source)
    if not rules then
        error("[ion7.grammar.from.abnf] failed to parse ABNF source")
    end

    local user_names = {}
    for _, r in ipairs(rules) do user_names[r.name] = true end

    local core = build_core_rules()

    -- Closure over `core ∪ user` references, seeded from user rule bodies.
    local needed = {}
    local function visit(body)
        local refs = {}
        collect_refs(body, refs)
        for ref_name in pairs(refs) do
            if not needed[ref_name] then
                needed[ref_name] = true
                if core[ref_name] and not user_names[ref_name] then
                    visit(core[ref_name])
                end
            end
        end
    end
    for _, r in ipairs(rules) do visit(r.body) end

    local builder = Builder.new()
    for name in pairs(needed) do
        if core[name] and not user_names[name] then
            builder:rule(name, core[name])
        end
    end
    for _, r in ipairs(rules) do
        builder:rule(r.name, r.body)
    end

    local root_name = root and root:lower() or rules[1] and rules[1].name
    if not root_name then
        error("[ion7.grammar.from.abnf] no rule defined")
    end
    builder:root(root_name)
    return builder
end

return {
    from_abnf = from_abnf,
}
