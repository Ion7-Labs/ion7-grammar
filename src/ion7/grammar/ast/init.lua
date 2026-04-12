--- @module ion7.grammar.ast
--- SPDX-License-Identifier: MIT
--- AST layer aggregator — re-exports `ion7.grammar.ast.nodes`.
---
--- The canonical require path `require "ion7.grammar.ast"` resolves here.
--- All node constructors (`literal`, `char`, `seq`, `alt`, `rep`, …) and
--- pre-built constants (`DIGIT`, `ALPHA`, `WS`, …) are available directly
--- on the returned table.
---
--- @author Ion7-Labs
--- @version 0.1.0

return require "ion7.grammar.ast.nodes"
