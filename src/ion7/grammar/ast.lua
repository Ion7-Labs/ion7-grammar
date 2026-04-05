--- @module ion7.grammar.ast
--- SPDX-License-Identifier: AGPL-3.0-or-later
--- Internal AST nodes for GBNF grammar construction.
---
--- Every grammar is built as an AST then compiled to a GBNF string.
--- This separation lets us: optimize the AST before compilation,
--- pretty-print, validate, and support future output formats.
---
--- Node types:
---   literal   "text"           exact string
---   char      [a-z0-9_]        character class
---   ref       rule_name        reference to another rule
---   seq       a b c            sequence (ordered)
---   alt       a | b | c        alternatives (unordered choice)
---   rep       a{n,m}           repetition with bounds
---   rule      name ::= body    named rule definition
---   group     ( node )         explicit parenthesis grouping
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast = {}

-- ── Node constructors ─────────────────────────────────────────────────────────

--- Exact string literal.
--- @param  s  string  The literal text.
--- @return node  { kind="literal", value=s }
function ast.literal(s)
    assert(type(s) == "string", "literal: expected string")
    return { kind = "literal", value = s }
end

--- Character class node.
--- @param  spec     string  Character class spec, e.g. "a-zA-Z0-9_" or "\\n\\t".
--- @param  negated  bool?   When true the class is negated: [^spec]. Default: false.
--- @return node  { kind="char", spec=spec, negated=negated }
function ast.char(spec, negated)
    return { kind = "char", spec = spec, negated = negated or false }
end

--- Reference to a named rule.
--- @param  name  string  Rule name to reference.
--- @return node  { kind="ref", name=name }
function ast.ref(name)
    return { kind = "ref", name = name }
end

--- Sequence: all nodes must match in left-to-right order.
--- Returns the single node unwrapped when only one argument is provided.
--- @param  ...  node  One or more AST nodes.
--- @return node  { kind="seq", items={...} } or the single node if only one.
function ast.seq(...)
    local items = { ... }
    if #items == 1 then return items[1] end
    return { kind = "seq", items = items }
end

--- Alternation: first matching alternative wins (ordered choice).
--- Returns the single node unwrapped when only one argument is provided.
--- @param  ...  node  One or more AST nodes.
--- @return node  { kind="alt", items={...} } or the single node if only one.
function ast.alt(...)
    local items = { ... }
    if #items == 1 then return items[1] end
    return { kind = "alt", items = items }
end

--- Repetition with explicit bounds.
--- @param  node  node    The node to repeat.
--- @param  min   number  Minimum repetitions. 0 means optional. Default: 0.
--- @param  max   number  Maximum repetitions. -1 means unlimited. Default: -1.
--- @return node  { kind="rep", node=node, min=min, max=max }
function ast.rep(node, min, max)
    return { kind = "rep", node = node, min = min or 0, max = max or -1 }
end

--- Zero or more repetitions (Kleene star).
--- @param  node  node  The node to repeat.
--- @return node
function ast.star(node)     return ast.rep(node, 0, -1) end

--- One or more repetitions (Kleene plus).
--- @param  node  node  The node to repeat.
--- @return node
function ast.plus(node)     return ast.rep(node, 1, -1) end

--- Zero or one occurrence (optional).
--- @param  node  node  The node to make optional.
--- @return node
function ast.opt(node)      return ast.rep(node, 0,  1) end

--- Exactly n repetitions.
--- @param  node  node    The node to repeat.
--- @param  n     number  The exact repeat count.
--- @return node
function ast.exactly(node, n) return ast.rep(node, n, n) end

--- Named rule definition (top-level grammar rule).
--- @param  name  string  Rule name. Must match [a-zA-Z_][a-zA-Z0-9_-]*.
--- @param  body  node    The rule body AST node.
--- @return node  { kind="rule", name=name, body=body }
function ast.rule(name, body)
    assert(type(name) == "string" and name:match("^[%a_][%a%d_%-]*$"),
        "rule: invalid name '" .. tostring(name) .. "'")
    return { kind = "rule", name = name, body = body }
end


-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Negated character class - any character NOT in the given spec.
--- @param  chars  string  Character class spec to negate.
--- @return node  Negated char node.
function ast.any_except(chars)
    return ast.char(chars, true)
end

--- Explicit parenthesis grouping.
--- Useful when an alt or seq needs to be treated as a single unit inside
--- another alt or rep, and the compiler's automatic grouping is insufficient.
--- @param  node  node  The node to wrap.
--- @return node  { kind="group", node=node }
function ast.group(node)
    return { kind = "group", node = node }
end


-- ── Pre-built common character class nodes ────────────────────────────────────

--- Decimal digit: [0-9]
ast.DIGIT = ast.char("0-9")
--- ASCII letter: [a-zA-Z]
ast.ALPHA = ast.char("a-zA-Z")
--- ASCII alphanumeric: [a-zA-Z0-9]
ast.ALNUM = ast.char("a-zA-Z0-9")
--- Whitespace character: [ \t\n]
ast.SPACE = ast.char(" \\t\\n")
--- Optional whitespace: [ \t\n]*
ast.WS    = ast.star(ast.SPACE)
--- Required whitespace: [ \t\n]+
ast.WS1   = ast.plus(ast.SPACE)
--- Any byte: [\x00-\xff]
ast.ANY   = ast.char("\\x00-\\xff")

return ast
