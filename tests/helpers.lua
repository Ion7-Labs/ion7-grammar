--- @module tests.helpers
--- @author  ion7 / Ion7 Project Contributors
---
--- Path bootstrap shared across the ion7-grammar test suite.
---
--- Tests are launched from the repo root and rely on the local
--- `src/ion7/...` layout, plus a sibling ion7-core checkout for the
--- bundled JSON wrapper, FFI bridge, and bound runtime helpers.
---
--- Environment :
---   ION7_CORE_SRC  Optional. Override the ion7-core source root.
---                  Defaults to the first match of `../ion7-core/src/`
---                  or `../../ion7-core/src/`.

local function _add_path(prefix)
    local extras = prefix .. "/?.lua;" .. prefix .. "/?/init.lua"
    if not package.path:find(extras, 1, true) then
        package.path = extras .. ";" .. package.path
    end
end

local function _bootstrap_paths()
    -- Local ion7-grammar sources first.
    _add_path("./src")

    local override = os.getenv("ION7_CORE_SRC")
    if override and override ~= "" then
        _add_path(override)
        return
    end
    for _, candidate in ipairs({
        "../ion7-core/src",
        "../../ion7-core/src",
    }) do
        local f = io.open(candidate .. "/ion7/core/init.lua", "r")
        if f then
            f:close()
            _add_path(candidate)
            return
        end
    end
end

_bootstrap_paths()

return {}
