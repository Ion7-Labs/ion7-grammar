--- @module ion7.grammar.regex
--- SPDX-License-Identifier: MIT
--- Regex → GBNF converter.
---
--- Parses a subset of PCRE/ERE regex and produces GBNF rules.
--- The model cannot generate tokens that don't match the regex.
---
--- Supported syntax:
---   .          Any character except newline
---   [abc]      Character class
---   [^abc]     Negated character class
---   [a-z]      Character range
---   \d \w \s   Digit, word char, whitespace (and \D \W \S negations)
---   \n \r \t   Escape sequences
---   a*         Zero or more
---   a+         One or more
---   a?         Optional
---   a{n}       Exactly n
---   a{n,m}     Between n and m
---   a{n,}      At least n
---   (abc)      Group
---   a|b        Alternation
---   abc        Sequence (implicit)
---
--- NOT supported (out of scope for GBNF context):
---   ^ $ anchors (GBNF has no positional concept)
---   (?:...) (?=...) lookahead/lookbehind
---   Backreferences \1
---
--- @author Ion7-Labs
--- @version 0.1.0

--- AST node table - field set depends on `kind`; see ast.lua.
--- @alias node table

local ast = require "ion7.grammar.ast"

-- ── Regex parser ──────────────────────────────────────────────────────────────

--- Recursive-descent regex parser. Internal to this module.
--- @class Parser
--- @field s         string  Input pattern string.
--- @field pos       number  Current read position (1-based).
--- @field _rule_idx number  Reserved for future sub-rule naming.
local Parser = {}
Parser.__index = Parser

--- Construct a new Parser over the given pattern string.
--- @param  s  string  Regex pattern.
--- @return Parser
function Parser.new(s)
    return setmetatable({ s = s, pos = 1, _rule_idx = 0 }, Parser)
end

--- Return the character at the current position without advancing.
--- @return string  Single character, or "" at EOF.
function Parser:peek()
    return self.s:sub(self.pos, self.pos)
end

--- Return true when the parser has consumed all input.
--- @return boolean
function Parser:eof()
    return self.pos > #self.s
end

--- Consume and return the current character, advancing the position by 1.
--- @return string  The consumed character.
function Parser:advance()
    local c = self:peek()
    self.pos = self.pos + 1
    return c
end

--- Consume the next character and assert it equals `c`.
--- Raises an error if the character does not match.
--- @param  c  string  Expected character.
function Parser:expect(c)
    local got = self:advance()
    if got ~= c then
        error(string.format("[ion7.grammar.regex] expected '%s' got '%s' at pos %d",
            c, got, self.pos - 1))
    end
end

--- Parse a character class body after the opening `[`.
--- Handles negation (`^`), ranges (`a-z`), and escape sequences.
--- @return node  ast.char node.
function Parser:parse_char_class()
    local negated = false
    if self:peek() == "^" then negated = true; self:advance() end
    local spec = ""
    while not self:eof() and self:peek() ~= "]" do
        local c = self:advance()
        if c == "\\" then
            local esc = self:advance()
            spec = spec .. "\\" .. esc
        else
            -- Check for range a-z
            if self:peek() == "-" and self.s:sub(self.pos + 1, self.pos + 1) ~= "]" then
                self:advance()  -- consume '-'
                local end_c = self:advance()
                spec = spec .. c .. "-" .. end_c
            else
                spec = spec .. c
            end
        end
    end
    self:expect("]")
    return ast.char(spec, negated)
end

--- Parse an escape sequence after the leading `\`.
---
--- Shorthand classes (\d, \w, \s and their uppercase negations) produce
--- char nodes; \n, \r, \t produce literal nodes; anything else is a
--- literal of the escaped character itself.
---
--- @return node  ast.char or ast.literal node.
function Parser:parse_escape()
    local c = self:advance()
    if     c == "d" then return ast.char("0-9")
    elseif c == "D" then return ast.char("0-9", true)
    elseif c == "w" then return ast.char("a-zA-Z0-9_")
    elseif c == "W" then return ast.char("a-zA-Z0-9_", true)
    elseif c == "s" then return ast.char(" \\t\\n\\r")
    elseif c == "S" then return ast.char(" \\t\\n\\r", true)
    elseif c == "n" then return ast.literal("\n")
    elseif c == "r" then return ast.literal("\r")
    elseif c == "t" then return ast.literal("\t")
    else return ast.literal(c)  -- escaped literal
    end
end

--- Parse a `{n}`, `{n,m}`, or `{n,}` quantifier body (after `{` consumed).
--- Returns min and max counts; max is -1 for unbounded.
--- @return number  min  Minimum repetition count.
--- @return number  max  Maximum repetition count (-1 = unlimited).
function Parser:parse_quantifier_braces()
    local s = ""
    while self:peek() ~= "}" and not self:eof() do
        s = s .. self:advance()
    end
    self:expect("}")
    local n, m = s:match("^(%d+),(%d*)$")
    if n then
        local lo = tonumber(n) or 0
        local hi = m == "" and -1 or (tonumber(m) or -1)
        return lo, hi
    end
    local exact = s:match("^(%d+)$")
    if exact then
        local v = tonumber(exact) or 0
        return v, v
    end
    error("[ion7.grammar.regex] invalid quantifier {" .. s .. "}")
end

--- Apply a quantifier suffix (`*`, `+`, `?`, `{n,m}`) to a node if present.
--- Returns the node unchanged when no quantifier follows.
--- @param  node  node  The atom to quantify.
--- @return node  Quantified (or original) node.
function Parser:apply_quant(node)
    local c = self:peek()
    if     c == "*" then self:advance(); return ast.star(node)
    elseif c == "+" then self:advance(); return ast.plus(node)
    elseif c == "?" then self:advance(); return ast.opt(node)
    elseif c == "{" then
        self:advance()
        local min_n, max_n = self:parse_quantifier_braces()
        return ast.rep(node, min_n, max_n)
    end
    return node
end

--- Parse a single atom: literal character, class, group, escape, or `.`.
--- Returns nil for anchors (`^`/`$`) and at end-of-alternation boundaries.
--- @return node?  AST node, or nil when no atom is available.
function Parser:parse_atom()
    local c = self:peek()
    if c == "(" then
        self:advance()
        -- Ignore non-capturing group marker (?:
        if self:peek() == "?" then
            self:advance()  -- ?
            self:advance()  -- : or other
        end
        local inner = self:parse_alt()
        self:expect(")")
        return inner
    elseif c == "[" then
        self:advance()
        return self:parse_char_class()
    elseif c == "\\" then
        self:advance()
        return self:parse_escape()
    elseif c == "." then
        self:advance()
        -- Any char except newline.
        return ast.char("\\n", true)
    elseif c == "^" or c == "$" then
        self:advance()
        return nil  -- Anchors are no-ops in GBNF.
    elseif c == "" or c == "|" or c == ")" or self:eof() then
        return nil
    else
        self:advance()
        return ast.literal(c)
    end
end

--- Parse a sequence of quantified atoms until an alternation boundary or EOF.
---
--- Consecutive unquantified literals are merged into a single literal node
--- so that `"yes"` compiles as `"yes"` rather than `"y" "e" "s"`.
---
--- @return node  ast.seq (or a single node when only one atom is found).
function Parser:parse_seq()
    local items = {}
    while not self:eof() do
        local c = self:peek()
        if c == "|" or c == ")" then break end
        local atom = self:parse_atom()
        if atom then
            -- Merge consecutive literals when no quantifier follows.
            local next_c    = self:peek()
            local has_quant = next_c == "*" or next_c == "+"
                           or next_c == "?" or next_c == "{"
            if not has_quant
                and atom.kind == "literal"
                and #items > 0
                and items[#items].kind == "literal" then
                items[#items].value = items[#items].value .. atom.value
            else
                atom = self:apply_quant(atom)
                items[#items + 1] = atom
            end
        end
    end
    if #items == 0 then return ast.literal("") end
    if #items == 1 then return items[1] end
    return ast.seq(table.unpack(items))
end

--- Parse a top-level alternation expression (`a|b|c`).
--- @return node  ast.alt (or a single node when there is only one branch).
function Parser:parse_alt()
    local alts = { self:parse_seq() }
    while self:peek() == "|" do
        self:advance()
        alts[#alts + 1] = self:parse_seq()
    end
    if #alts == 1 then return alts[1] end
    return ast.alt(table.unpack(alts))
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Convert a regex string to a GBNF rule body (AST node).
---
--- The returned node can be passed directly to Builder:rule() or used
--- inside larger AST expressions.
---
--- @param  pattern  string  ERE/PCRE subset regex pattern.
--- @return node  AST node representing the pattern.
--- @error  On unrecognised syntax or unconsumed input after parsing.
local function to_ast(pattern)
    local p = Parser.new(pattern)
    local result = p:parse_alt()
    if not p:eof() then
        error(string.format(
            "[ion7.grammar.regex] unexpected char '%s' at pos %d",
            p:peek(), p.pos))
    end
    return result
end

--- Convert a regex pattern directly to a single-rule GBNF string.
---
--- Equivalent to wrapping `to_ast` in a one-rule builder and compiling.
--- Whitespace injection is disabled (regex grammars rarely reference `ws`).
---
--- @param  pattern  string   ERE/PCRE subset regex pattern.
--- @param  name     string?  Root rule name (default: "root").
--- @return string   GBNF string.
local function to_gbnf(pattern, name)
    name = name or "root"
    local compiler_m = require "ion7.grammar.compiler"
    local body = to_ast(pattern)
    return compiler_m.compile({{ name = name, body = body }}, name, false)
end

return {
    to_ast  = to_ast,
    to_gbnf = to_gbnf,
}
