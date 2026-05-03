--- @module ion7.grammar.from.regex
--- SPDX-License-Identifier: MIT
--- ERE regex → GBNF converter.
---
--- Converts a subset of PCRE/ERE regex into ion7 AST nodes (or a complete
--- GBNF string). Typically accessed via `Grammar.from_regex()`.
---
--- Supported syntax:
---   `.`        Any character except newline
---   `[abc]`    Character class
---   `[^abc]`   Negated character class
---   `[a-z]`    Character range
---   `\d \w \s` Digit, word char, whitespace (and `\D \W \S` negations)
---   `\n \r \t` Escape sequences
---   `a*`       Zero or more
---   `a+`       One or more
---   `a?`       Optional
---   `a{n}`     Exactly n repetitions
---   `a{n,m}`   Between n and m repetitions
---   `a{n,}`    At least n repetitions
---   `(abc)`    Group (non-capturing)
---   `(?:abc)`  Non-capturing group (same as the above)
---   `a|b`      Alternation
---   `abc`      Implicit sequence
---
--- Not supported: `^` `$` anchors (consumed and ignored), lookahead/
--- lookbehind, backreferences.
---
--- @usage
---   local regex_m = require "ion7.grammar.from.regex"
---   local gbnf = regex_m.to_gbnf("\\d{4}-\\d{2}-\\d{2}", "date")
---   -- date ::= [0-9]{4} "-" [0-9]{2} "-" [0-9]{2}
---
--- @author Ion7-Labs
--- @version 0.1.0

local lpeg = require "lpeg"
local ast  = require "ion7.grammar.ast"

local P, S, R, V    = lpeg.P, lpeg.S, lpeg.R, lpeg.V
local C, Cc, Ct, Cs = lpeg.C, lpeg.Cc, lpeg.Ct, lpeg.Cs

local table_unpack = table.unpack or unpack
local ipairs       = ipairs

-- ── AST helpers ───────────────────────────────────────────────────────────────

--- Merge runs of adjacent `literal` nodes into a single literal so that
--- `abc` compiles to `"abc"` rather than `"a" "b" "c"`. Empty literals
--- (which surface only when an anchor is consumed) are dropped.
local function merge_literals(items)
    local out, n = {}, 0
    for _, it in ipairs(items) do
        if it then
            local last = out[n]
            if last and last.kind == "literal" and it.kind == "literal" then
                last.value = last.value .. it.value
            elseif it.kind == "literal" and it.value == "" then
                -- skip
            else
                n = n + 1
                out[n] = it
            end
        end
    end
    return out, n
end

--- Build a seq / single-item / empty AST from a captured items list.
local function seq_from_items(items)
    local merged, n = merge_literals(items)
    if n == 0 then return ast.literal("") end
    if n == 1 then return merged[1] end
    return ast.seq(table_unpack(merged))
end

--- Wrap with the requested quantifier (or pass through when nil).
local function apply_quant(node, quant)
    if not quant or not node then return node end
    local kind = quant[1]
    if kind == "*" then return ast.star(node) end
    if kind == "+" then return ast.plus(node) end
    if kind == "?" then return ast.opt(node)  end
    return ast.rep(node, quant[2], quant[3])
end

-- ── Captures for atomic regex elements ────────────────────────────────────────

--- Single-char escape outside of a char class.
local function build_escape(c)
    if c == "d" then return ast.char("0-9")
    elseif c == "D" then return ast.char("0-9", true)
    elseif c == "w" then return ast.char("a-zA-Z0-9_")
    elseif c == "W" then return ast.char("a-zA-Z0-9_", true)
    elseif c == "s" then return ast.char(" \\t\\n\\r")
    elseif c == "S" then return ast.char(" \\t\\n\\r", true)
    elseif c == "n" then return ast.literal("\n")
    elseif c == "r" then return ast.literal("\r")
    elseif c == "t" then return ast.literal("\t")
    end
    return ast.literal(c)
end

--- Char-class spec: keeps backslash escapes intact so `[\d]` lands as
--- `ast.char("\\d")`, mirroring how character ranges are encoded for GBNF.
local cc_inner   = (P "\\" * P(1) + (P(1) - P "]"))^0
local char_class = P "[" * (
        (P "^" * C(cc_inner)) / function(spec) return ast.char(spec, true)  end
      + C(cc_inner)            / function(spec) return ast.char(spec, false) end
    ) * P "]"

local escape = (P "\\" * C(P(1))) / build_escape

local dot = P "." / function() return ast.char("\\n", true) end

-- Anchors are consumed but produce no AST node.
local anchor = (P "^" + P "$") * Cc(nil)

-- A literal char: anything that is not a regex metacharacter.
local meta    = S "()[]{}.|*+?\\^$"
local literal = (P(1) - meta) / function(c) return ast.literal(c) end

-- ── Quantifier captures ───────────────────────────────────────────────────────

local digits = R "09"

--- `{n}`, `{n,m}`, `{n,}` → a 3-tuple `{ "{}", min, max }` consumed by apply_quant.
local brace_quant = P "{" * (
        (C(digits^1) * P "," * C(digits^1)) / function(n, m)
            return { "{}", tonumber(n), tonumber(m) }
        end
      + (C(digits^1) * P ",")  / function(n) return { "{}", tonumber(n), -1 } end
      + C(digits^1)            / function(n) local v = tonumber(n)
                                              return { "{}", v, v } end
    ) * P "}"

--- Single-char quantifiers tagged the same shape.
local single_quant = (C(S "*+?") / function(c) return { c } end)

local quantifier = brace_quant + single_quant

-- ── Grammar ───────────────────────────────────────────────────────────────────

local regex_grammar = P{ "alt",
    -- Top level: `a|b|c`. One alt is a degenerate match of the inner seq.
    alt = (V "seq" * (P "|" * V "seq")^0) / function(...)
        local parts = { ... }
        if #parts == 1 then return parts[1] end
        return ast.alt(table_unpack(parts))
    end,

    -- A seq is an arbitrary sequence of quantified atoms.
    seq = Ct(V "quant_atom"^0) / seq_from_items,

    -- An atom optionally followed by a quantifier.
    quant_atom = (V "atom" * quantifier^-1) / apply_quant,

    -- An atom is one of: group, char class, escape, dot, anchor, literal.
    atom = V "group" + char_class + escape + dot + anchor + literal,

    -- Groups are non-capturing in this dialect; `(?:...)` is accepted so
    -- patterns ported from PCRE land without manual stripping.
    group = P "(" * (P "?:")^-1 * V "alt" * P ")",
}

-- ── Public API ────────────────────────────────────────────────────────────────

local full_grammar = regex_grammar * P(-1)

--- Convert a regex string to an AST node.
--- @param  pattern  string  ERE/PCRE subset regex pattern.
--- @return node  AST node representing the pattern.
local function to_ast(pattern)
    local node = full_grammar:match(pattern)
    if node == nil then
        error("[ion7.grammar.from.regex] failed to parse pattern: " .. pattern)
    end
    return node
end

--- Convert a regex pattern directly to a single-rule GBNF string.
--- @param  pattern  string   ERE/PCRE subset regex pattern.
--- @param  name     string?  Root rule name (default: "root").
--- @return string   GBNF string.
local function to_gbnf(pattern, name)
    name = name or "root"
    local compiler_m = require "ion7.grammar.ast.compiler"
    local body = to_ast(pattern)
    return compiler_m.compile({{ name = name, body = body }}, name, false)
end

return {
    to_ast  = to_ast,
    to_gbnf = to_gbnf,
}
