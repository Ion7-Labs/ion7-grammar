## ion7-grammar — build targets

ION7_DOC  ?= ../ion7-doc
DOCS_OUT  ?= $(abspath docs)

# ── Tests ─────────────────────────────────────────────────────────────────────

.PHONY: test
test:
	luajit tests/test_pure.lua

# ── Documentation ─────────────────────────────────────────────────────────────

.PHONY: docs
docs:
	luajit $(ION7_DOC)/bin/gendoc.lua grammar $(DOCS_OUT) $(abspath README.md)

.PHONY: docs-open
docs-open: docs
	xdg-open $(DOCS_OUT)/grammar/index.html 2>/dev/null || open $(DOCS_OUT)/grammar/index.html
