--- SPDX-License-Identifier: MIT
--- AST layer aggregator.
---
--- Re-exports ion7.grammar.ast.nodes so that the canonical path
--- `require "ion7.grammar.ast"` continues to work after the move to
--- the ast/ subdirectory.
---
--- @author Ion7-Labs
--- @version 0.1.0

return require "ion7.grammar.ast.nodes"
