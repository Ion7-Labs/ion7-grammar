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

local ast = require "ion7.grammar.ast"

-- ── Regex parser ──────────────────────────────────────────────────────────────

--- @class RegexParser
local Parser = {}
Parser.__index = Parser

function Parser.new(s)
    return setmetatable({ s = s, pos = 1 }, Parser)
end

function Parser:peek()
    return self.s:sub(self.pos, self.pos)
end

function Parser:eof()
    return self.pos > #self.s
end

function Parser:advance()
    local c = self:peek()
    self.pos = self.pos + 1
    return c
end

function Parser:expect(c)
    local got = self:advance()
    if got ~= c then
        error(string.format("[ion7.grammar.from.regex] expected '%s' got '%s' at pos %d",
            c, got, self.pos - 1))
    end
end

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
            if self:peek() == "-" and self.s:sub(self.pos + 1, self.pos + 1) ~= "]" then
                self:advance()
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
    else return ast.literal(c)
    end
end

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
    error("[ion7.grammar.from.regex] invalid quantifier {" .. s .. "}")
end

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

function Parser:parse_atom()
    local c = self:peek()
    if c == "(" then
        self:advance()
        if self:peek() == "?" then
            self:advance(); self:advance()
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
        return ast.char("\\n", true)
    elseif c == "^" or c == "$" then
        self:advance()
        return nil
    elseif c == "" or c == "|" or c == ")" or self:eof() then
        return nil
    else
        self:advance()
        return ast.literal(c)
    end
end

function Parser:parse_seq()
    local items = {}
    while not self:eof() do
        local c = self:peek()
        if c == "|" or c == ")" then break end
        local atom = self:parse_atom()
        if atom then
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
--- @param  pattern  string  ERE/PCRE subset regex pattern.
--- @return node  AST node representing the pattern.
local function to_ast(pattern)
    local p = Parser.new(pattern)
    local result = p:parse_alt()
    if not p:eof() then
        error(string.format(
            "[ion7.grammar.from.regex] unexpected char '%s' at pos %d",
            p:peek(), p.pos))
    end
    return result
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
