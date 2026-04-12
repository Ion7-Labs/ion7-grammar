--- @module ion7.grammar.runtime.context
--- SPDX-License-Identifier: MIT
--- Stateful grammar that evolves with the conversation.
---
--- Standard grammars are static per request. `GrammarContext` is a live
--- object that accumulates knowledge and updates the grammar as your
--- application state changes — without rebuilding from scratch each turn.
---
--- @usage
---   local gc = Grammar.context()
---
---   -- Register live schema
---   gc:learn_enum("status", { "pending", "active", "closed" })
---   gc:learn_table("users", { "id", "name", "email" })
---
---   -- Compile current grammar (cached until invalidated)
---   local g = gc:current()
---
---   -- Grammar grows with the conversation
---   gc:learn_table("orders", { "id", "user_id", "total" })
---
---   -- Branch and restore
---   local snap = gc:snapshot()
---   gc:learn_enum("color", { "red", "blue" })
---   gc:restore(snap)  -- back to before color
---
--- @author Ion7-Labs
--- @version 0.1.0

local Builder = require "ion7.grammar.ast.builder"
local ast     = require "ion7.grammar.ast"
local Dynamic = require "ion7.grammar.from.dynamic"

-- ── Grammar_obj compatibility metatable ──────────────────────────────────────
-- Defined once at module level, not recreated on every current() call.
-- Methods use self._builder so each instance captures its own builder.
local _ctx_grammar_mt = {}
_ctx_grammar_mt.__index = _ctx_grammar_mt

function _ctx_grammar_mt:to_gbnf(root)
    if root then self._builder:root(root) end
    return self._builder:compile()
end

function _ctx_grammar_mt:builder()
    return self._builder
end

function _ctx_grammar_mt:rules()
    return self._builder:names()
end

function _ctx_grammar_mt:merge()
    error("[ion7.grammar.runtime.context] context grammar: use learn_* to add rules")
end

--- @class GrammarContext
local GrammarContext = {}
GrammarContext.__index = GrammarContext

--- Create a new GrammarContext.
--- @param  opts  table?
---   opts.root  string?  Default root rule name (default: "root").
--- @return GrammarContext
function GrammarContext.new(opts)
    opts = opts or {}
    return setmetatable({
        _root    = opts.root or "root",
        _enums   = {},   -- { rule_name → { values } }
        _tables  = {},   -- { table_name → { columns } }
        _tools   = {},   -- { tool } array
        _extra   = {},   -- { name, body } extra rules
        _dirty   = true, -- needs rebuild
        _cached  = nil,  -- cached Grammar_obj
    }, GrammarContext)
end

--- @private
function GrammarContext:_invalidate()
    self._dirty  = true
    self._cached = nil
    return self
end

--- Register an enum whitelist (creates or replaces a named rule).
--- @param  rule_name  string  Rule name.
--- @param  values     table   Array of allowed string values.
--- @return GrammarContext  self
function GrammarContext:learn_enum(rule_name, values)
    assert(type(rule_name) == "string" and type(values) == "table",
        "[ion7.grammar.runtime.context] learn_enum: rule_name (string) and values (table) required")
    self._enums[rule_name] = values
    return self:_invalidate()
end

--- Register a database table with its column names.
--- Creates two rules: `<table>` (the table name) and `<table>_col` (columns).
--- Also updates combined `table_name` and `column_name` enums.
---
--- @param  name     string  Table name.
--- @param  columns  table   Array of column name strings.
--- @return GrammarContext  self
function GrammarContext:learn_table(name, columns)
    assert(type(name) == "string" and type(columns) == "table",
        "[ion7.grammar.runtime.context] learn_table: name (string) and columns (table) required")
    self._tables[name] = columns
    return self:_invalidate()
end

--- Register a tool definition (for tool-call grammars).
--- @param  name    string  Tool name.
--- @param  schema  table?  JSON Schema for arguments.
--- @return GrammarContext  self
function GrammarContext:learn_tool(name, schema)
    assert(type(name) == "string",
        "[ion7.grammar.runtime.context] learn_tool: name must be a string")
    for i, t in ipairs(self._tools) do
        if t.name == name then
            self._tools[i] = { name = name, schema = schema or { type = "object" } }
            return self:_invalidate()
        end
    end
    self._tools[#self._tools+1] = { name = name, schema = schema or { type = "object" } }
    return self:_invalidate()
end

--- Add or replace a custom rule.
--- @param  rule_name  string  Rule name.
--- @param  body       any     AST node.
--- @return GrammarContext  self
function GrammarContext:learn_rule(rule_name, body)
    for i, r in ipairs(self._extra) do
        if r.name == rule_name then
            self._extra[i] = { name = rule_name, body = body }
            return self:_invalidate()
        end
    end
    self._extra[#self._extra+1] = { name = rule_name, body = body }
    return self:_invalidate()
end

--- Remove a learned rule, enum, table, or tool.
--- @param  name  string  Rule/table/tool name to forget.
--- @return GrammarContext  self
function GrammarContext:forget(name)
    self._enums[name]  = nil
    self._tables[name] = nil
    for i, t in ipairs(self._tools) do
        if t.name == name then table.remove(self._tools, i); break end
    end
    for i, r in ipairs(self._extra) do
        if r.name == name then table.remove(self._extra, i); break end
    end
    return self:_invalidate()
end

--- Build and return the current grammar object reflecting all learned knowledge.
--- Result is cached until a learn_* or forget() call invalidates it.
--- @return any  Grammar_obj (via _ctx_grammar_mt)
function GrammarContext:current()
    if not self._dirty and self._cached then
        return self._cached
    end

    local b = Builder.new({ root = self._root })

    b:rule("ws", ast.star(ast.char(" \\t\\n")))

    -- Add enum rules
    for rule_name, values in pairs(self._enums) do
        if #values > 0 then
            local sub = Dynamic.from_enum(rule_name, values)
            for _, r in ipairs(sub._rules) do
                if not b._names[r.name] then b:rule(r.name, r.body) end
            end
        end
    end

    -- Add table rules
    local all_table_names  = {}
    local all_column_names = {}
    for tname, cols in pairs(self._tables) do
        all_table_names[#all_table_names+1] = tname
        local col_rule = tname .. "-col"
        if #cols > 0 then
            local sub = Dynamic.from_enum(col_rule, cols)
            for _, r in ipairs(sub._rules) do
                if not b._names[r.name] then b:rule(r.name, r.body) end
            end
        end
        for _, c in ipairs(cols) do
            all_column_names[#all_column_names+1] = c
        end
    end

    if #all_table_names > 0 then
        local sub_t = Dynamic.from_enum("table-name", all_table_names)
        for _, r in ipairs(sub_t._rules) do
            if not b._names[r.name] then b:rule(r.name, r.body) end
        end
    end
    if #all_column_names > 0 then
        local seen = {}; local uniq = {}
        for _, c in ipairs(all_column_names) do
            if not seen[c] then seen[c]=true; uniq[#uniq+1]=c end
        end
        local sub_c = Dynamic.from_enum("column-name", uniq)
        for _, r in ipairs(sub_c._rules) do
            if not b._names[r.name] then b:rule(r.name, r.body) end
        end
    end

    -- Add tool rules
    if #self._tools > 0 then
        local sub_tools = Dynamic.from_tools(self._tools)
        for _, r in ipairs(sub_tools._rules) do
            if not b._names[r.name] then b:rule(r.name, r.body) end
        end
        if not b._names[self._root] and b._names["tool-call"] then
            b:rule(self._root, ast.ref("tool-call"))
        end
    end

    -- Add extra custom rules
    for _, r in ipairs(self._extra) do
        if not b._names[r.name] then b:rule(r.name, r.body) end
    end

    -- Ensure a root rule exists
    if not b._names[self._root] then
        local first = nil
        for _, r in ipairs(b._rules) do
            if r.name ~= "ws" then first = r.name; break end
        end
        if first then
            b:rule(self._root, ast.ref(first))
        else
            b:rule(self._root, ast.literal(""))
        end
    end

    self._cached = setmetatable({ _builder = b }, _ctx_grammar_mt)
    self._dirty  = false
    return self._cached
end

--- Serialize current state for snapshot/restore.
--- @return table  Snapshot of current learned state.
function GrammarContext:snapshot()
    local snap = {
        root   = self._root,
        enums  = {},
        tables = {},
        tools  = {},
        extra  = {},
    }
    for k, v in pairs(self._enums) do
        snap.enums[k] = {}
        for i, val in ipairs(v) do snap.enums[k][i] = val end
    end
    for k, v in pairs(self._tables) do
        snap.tables[k] = {}
        for i, col in ipairs(v) do snap.tables[k][i] = col end
    end
    for i, t in ipairs(self._tools) do
        snap.tools[i] = { name = t.name, schema = t.schema }
    end
    for i, r in ipairs(self._extra) do
        snap.extra[i] = { name = r.name, body = r.body }
    end
    return snap
end

--- Restore state from a snapshot.
--- @param  snap  table  From GrammarContext:snapshot().
--- @return GrammarContext  self
function GrammarContext:restore(snap)
    self._root   = snap.root or "root"
    self._enums  = {}
    self._tables = {}
    self._tools  = {}
    self._extra  = {}
    for k, v in pairs(snap.enums)  do self._enums[k]  = v end
    for k, v in pairs(snap.tables) do self._tables[k] = v end
    for _, t in ipairs(snap.tools) do self._tools[#self._tools+1] = t end
    for _, r in ipairs(snap.extra) do self._extra[#self._extra+1] = r end
    return self:_invalidate()
end

--- Return a summary of what this context has learned.
--- @return table  { n_enums, n_tables, n_tools, n_extra }
function GrammarContext:stats()
    local n_enum, n_table, n_tool, n_extra = 0, 0, 0, 0
    for _ in pairs(self._enums)  do n_enum  = n_enum  + 1 end
    for _ in pairs(self._tables) do n_table = n_table + 1 end
    n_tool  = #self._tools
    n_extra = #self._extra
    return {
        n_enums  = n_enum,
        n_tables = n_table,
        n_tools  = n_tool,
        n_extra  = n_extra,
    }
end

return GrammarContext
