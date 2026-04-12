--- SPDX-License-Identifier: MIT
--- AST node constructors for GBNF grammars.
---
--- Every function returns a plain Lua table with a `kind` field.
--- These tables are the atoms that Builder and Composer operate on.
---
--- Node kinds:
---   literal  { kind, value }
---   char     { kind, spec, negated }
---   ref      { kind, name }
---   seq      { kind, items[] }
---   alt      { kind, items[] }
---   rep      { kind, node, min, max }  max=-1 means unlimited
---   group    { kind, node }
---
--- @author Ion7-Labs
--- @version 0.1.0

local ast = {}

--- Exact string literal node.
--- @param  s  string  Literal value.
--- @return node  { kind="literal", value=s }
function ast.literal(s)
    assert(type(s) == "string", "literal: expected string")
    return { kind = "literal", value = s }
end

--- Character class node.
--- @param  spec     string    Character class spec, e.g. "a-zA-Z0-9_" or "\\n\\t".
--- @param  negated  boolean?  When true the class is negated: [^spec]. Default: false.
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
--- Single-node form unwraps (passthrough) for ergonomic use.
--- @param  ...  node  One or more AST nodes.
--- @return node  { kind="seq", items={...} } or unwrapped node when only one.
function ast.seq(...)
    local items = { ... }
    assert(#items >= 1, "seq: at least one item required")
    if #items == 1 then return items[1] end
    return { kind = "seq", items = items }
end

--- Alternation: first matching branch wins.
--- Single-node form unwraps (passthrough) for ergonomic use.
--- @param  ...  node  One or more alternative AST nodes.
--- @return node  { kind="alt", items={...} } or unwrapped node when only one.
function ast.alt(...)
    local items = { ... }
    assert(#items >= 1, "alt: at least one alternative required")
    if #items == 1 then return items[1] end
    return { kind = "alt", items = items }
end

--- Repetition with explicit bounds.
--- @param  node  node    Inner node to repeat.
--- @param  min   number? Minimum repetitions (>= 0). Default: 0.
--- @param  max   number? Maximum repetitions (-1 = unlimited). Default: -1.
--- @return node  { kind="rep", node=node, min=min, max=max }
function ast.rep(node, min, max)
    min = min or 0
    max = max or -1
    assert(min >= 0, "rep: min must be >= 0")
    return { kind = "rep", node = node, min = min, max = max }
end

--- Zero or more repetitions.
--- @param  node  node
--- @return node
function ast.star(node) return ast.rep(node, 0, -1) end

--- One or more repetitions.
--- @param  node  node
--- @return node
function ast.plus(node) return ast.rep(node, 1, -1) end

--- Zero or one (optional).
--- @param  node  node
--- @return node
function ast.opt(node) return ast.rep(node, 0, 1) end

--- Exactly N repetitions.
--- @param  node  node
--- @param  n     number
--- @return node
function ast.exactly(node, n) return ast.rep(node, n, n) end

--- Explicit grouping (for readability / precedence).
--- @param  node  node
--- @return node  { kind="group", node=node }
function ast.group(node)
    return { kind = "group", node = node }
end

--- Negated character class shorthand: [^spec].
--- @param  spec  string  Characters to exclude.
--- @return node  { kind="char", spec=spec, negated=true }
function ast.any_except(spec)
    return ast.char(spec, true)
end

--- Named rule node (used internally by Builder).
--- Rule names must match [a-z][a-z0-9-]*.
--- @param  name  string  Rule name.
--- @param  body  node    Rule body.
--- @return node  { kind="rule", name=name, body=body }
function ast.rule(name, body)
    assert(type(name) == "string" and name:match("^[a-z][a-z0-9%-]*$"),
        "rule: invalid rule name '" .. tostring(name) .. "'")
    return { kind = "rule", name = name, body = body }
end

-- ── Common char class shortcuts ───────────────────────────────────────────────

--- [0-9]
ast.DIGIT = ast.char("0-9")
--- [a-zA-Z]
ast.ALPHA = ast.char("a-zA-Z")
--- [a-zA-Z0-9]
ast.ALNUM = ast.char("a-zA-Z0-9")
--- [ \t\n\r]
ast.SPACE = ast.char(" \\t\\n\\r")
--- optional whitespace: [ \t\n\r]*
ast.WS = ast.star(ast.char(" \\t\\n\\r"))

return ast
