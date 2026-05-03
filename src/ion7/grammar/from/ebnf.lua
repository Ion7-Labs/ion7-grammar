--- @module ion7.grammar.from.ebnf
--- SPDX-License-Identifier: MIT
--- W3C EBNF → GBNF converter.
---
--- Parses the EBNF dialect used in W3C specifications (XML, JSON, SVG,
--- XPath, …) and produces an ion7 grammar Builder. This dialect is
--- distinct from ISO/IEC 14977 EBNF — it favours regex-style postfix
--- quantifiers and `[...]` character classes over the explicit
--- repetition syntax of ISO EBNF.
---
--- Supported syntax:
---   Name ::= rhs                  Rule definition
---   "literal" or 'literal'        String literals
---   #xNN                          Hex char code
---   [a-zA-Z]                      Character class (regex-like)
---   [^abc]                        Negated character class
---   item?                         Optional
---   item*                         Zero or more
---   item+                         One or more
---   item1 item2                   Concatenation
---   item1 | item2                 Alternation
---   ( item )                      Group
---   /* … */                       Block comment
---
--- Differences from strict W3C notation:
---   - The minus operator (`A - B`, set difference) is rejected;
---     model it explicitly via the parent grammar.
---
--- @usage
---   local Grammar = require "ion7.grammar"
---   local g = Grammar.from_ebnf([[
---       Date     ::= Year "-" Month "-" Day
---       Year     ::= Digit Digit Digit Digit
---       Month    ::= Digit Digit
---       Day      ::= Digit Digit
---       Digit    ::= [0-9]
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
local string_format = string.format
local string_char   = string.char
local tonumber      = tonumber
local ipairs        = ipairs

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function alt_or_single(parts)
    if #parts == 1 then return parts[1] end
    return ast.alt(table_unpack(parts))
end

local function seq_or_single(parts)
    if #parts == 1 then return parts[1] end
    return ast.seq(table_unpack(parts))
end

local function apply_quant(node, quant)
    if not quant then return node end
    if quant == "?" then return ast.opt(node)  end
    if quant == "*" then return ast.star(node) end
    if quant == "+" then return ast.plus(node) end
    return node
end

local function hex_to_char(hex)
    local n = tonumber(hex, 16)
    if n < 0x20 or n == 0x22 or n == 0x5c or n > 0x7e then
        return ast.char(string_format("\\x%02x", n))
    end
    return ast.literal(string_char(n))
end

-- ── LPeg primitives ───────────────────────────────────────────────────────────

local digit  = R "09"
local alpha  = R("AZ", "az")
local hexdig = digit + R("AF", "af")

-- Whitespace + comments (block comments only — line comments do not
-- exist in W3C EBNF).
local block_comment = P "/*" * (P(1) - P "*/")^0 * P "*/"
local ws_unit       = S " \t\r\n" + block_comment
local ws            = ws_unit^0

-- Rule names: letter (letter | digit | _)* — capitalisation preserved
-- so that user references match exactly, but the lookup is normalised
-- to lowercase to play nicely with GBNF rule-name conventions.
local rulename = (C(alpha * (alpha + digit + P "_")^0)) / function(name)
    return name:lower():gsub("_", "-")
end

-- ── String literals ───────────────────────────────────────────────────────────

local sq_body = C((P(1) - P "'")^0)
local dq_body = C((P(1) - P '"')^0)
local string_lit = (P "'" * sq_body * P "'" + P '"' * dq_body * P '"')
                 / function(s) return ast.literal(s) end

-- ── Hex char codes ────────────────────────────────────────────────────────────

local hex_code = P "#x" * C(hexdig^1) / hex_to_char

-- ── Character classes (regex-style) ───────────────────────────────────────────

local cc_inner = C( (P "\\" * P(1) + (P(1) - P "]"))^0 )
local char_class = P "[" * (
        (P "^" * cc_inner) / function(spec) return ast.char(spec, true)  end
      + cc_inner            / function(spec) return ast.char(spec, false) end
    ) * P "]"

-- ── Reject difference operator ────────────────────────────────────────────────

local minus_op = P "-" * #(ws * (P "[" + P "'" + P '"' + P "#x" + alpha))
              / function() error("[ion7.grammar.from.ebnf] difference operator (A - B) is not supported") end

-- ── Grammar ───────────────────────────────────────────────────────────────────

local quant = S "?*+"

local ebnf_grammar = P{ "rulelist",

    rulelist = ws * Ct(V "rule"^1) * ws * P(-1),

    rule = ws * Ct(rulename * ws * P "::=" * ws * Cg(V "alternation", "body")) * ws
        / function(t) return { name = t[1], body = t.body } end,

    alternation = Ct(V "concat" * (ws * P "|" * ws * V "concat")^0)
        / alt_or_single,

    concat = Ct(V "quant_atom" * (ws * V "quant_atom")^0)
        / seq_or_single,

    quant_atom = (V "atom" * (C(quant)^-1)) / apply_quant,

    atom = V "group"
         + char_class
         + hex_code
         + string_lit
         + minus_op
         + (rulename * -(ws * P "::=")) / function(name) return ast.ref(name) end,

    group = P "(" * ws * V "alternation" * ws * P ")",
}

-- ── Public API ────────────────────────────────────────────────────────────────

--- Parse an EBNF string into a Builder.
---
--- @param  source  string   W3C-style EBNF rulelist.
--- @param  root    string?  Root rule name (default: first defined rule).
--- @return Builder
local function from_ebnf(source, root)
    local rules = ebnf_grammar:match(source)
    if not rules then
        error("[ion7.grammar.from.ebnf] failed to parse EBNF source")
    end

    local builder = Builder.new()
    for _, r in ipairs(rules) do
        builder:rule(r.name, r.body)
    end

    local root_name
    if root then
        root_name = root:lower():gsub("_", "-")
    elseif rules[1] then
        root_name = rules[1].name
    end
    if not root_name then
        error("[ion7.grammar.from.ebnf] no rule defined")
    end
    builder:root(root_name)
    return builder
end

return {
    from_ebnf = from_ebnf,
}
