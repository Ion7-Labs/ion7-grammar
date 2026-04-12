#!/usr/bin/env bash
# Run the full ion7-grammar test suite.
#
# Usage (no model):
#   bash tests/run_all.sh
#
# Usage (with model - enables DCCD + grammar sampler tests):
#   ION7_MODEL=/path/to/model.gguf \
#   ION7_CORE_PATH=../ion7-core \
#   LLAMA_LIB=/path/to/libllama.so \
#   bash tests/run_all.sh
#
# Optional env vars:
#   ION7_CORE_PATH   Path to ion7-core source (default: ../ion7-core)
#   ION7_LIB_DIR     Bridge/llama lib directory
#   LLAMA_LIB        Explicit path to libllama.so

set -euo pipefail

PASS=0
FAIL=0

# Resolve to grammar root regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

run_suite() {
    local name="$1"
    local file="$2"
    shift 2
    printf "\n\033[1m══ %-42s \033[0m%s\n" "$name" "$(printf '═%.0s' {1..16})"
    if ION7_MODEL="${ION7_MODEL:-}" \
       ION7_CORE_PATH="${ION7_CORE_PATH:-../ion7-core}" \
       ION7_LIB_DIR="${ION7_LIB_DIR:-}" \
       LLAMA_LIB="${LLAMA_LIB:-}" \
       luajit "$file" "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

# ── Suite 1: Pure Lua - no model required ─────────────────────────────────────
run_suite "Pure Lua (no model)" tests/test_pure.lua

# ── Suite 2 & 3: Model-dependent ─────────────────────────────────────────────
if [ -n "${ION7_MODEL:-}" ]; then
    run_suite "Model - grammar sampler integration" tests/test_model.lua
    run_suite "Model - DCCD end-to-end"             tests/test_dccd_model.lua
else
    printf "\n  \033[33m[SKIP]\033[0m Model tests - set ION7_MODEL=/path/to/model.gguf\n"
    printf "         Also set ION7_CORE_PATH if ion7-core is not at ../ion7-core\n"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n\033[1m%s\033[0m\n" "$(printf '═%.0s' {1..60})"
printf "  Suites: \033[32m%d passed\033[0m" "$PASS"
[ "$FAIL" -gt 0 ] && printf "  \033[31m%d FAILED\033[0m" "$FAIL"
printf "\n\033[1m%s\033[0m\n" "$(printf '═%.0s' {1..60})"

[ "$FAIL" -eq 0 ]
