-- test_runner.lua — Suwayomi+ & MaxOutUI feature test suite entry point
--
-- Run from KOReader's terminal plugin:
--   lua /mnt/us/koreader/plugins/suwayomiplus.koplugin/tests/test_runner.lua
--
-- Or from a desktop Lua interpreter for development:
--   lua suwayomiplus/tests/test_runner.lua

-- ---------------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------------

local function script_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[/\\])") or "./"
end

local TESTS_DIR = script_dir()

-- ---------------------------------------------------------------------------
-- Assertion helpers (exported as globals so dofile'd test files can use them)
-- ---------------------------------------------------------------------------

local total_passed = 0
local total_failed = 0
local total_errors = {}
local current_suite = "?"

function assert_eq(a, b, label)
    if a == b then
        total_passed = total_passed + 1
        print("    PASS: " .. tostring(label))
    else
        total_failed = total_failed + 1
        local msg = tostring(label)
            .. "\n           expected: " .. tostring(b)
            .. "\n                got: " .. tostring(a)
        table.insert(total_errors, "[" .. current_suite .. "] " .. tostring(label)
            .. " — expected " .. tostring(b) .. " got " .. tostring(a))
        print("    FAIL: " .. msg)
    end
end

function assert_true(v, label)
    assert_eq(not not v, true, label)
end

function assert_false(v, label)
    assert_eq(not not v, false, label)
end

function assert_not_nil(v, label)
    if v ~= nil then
        total_passed = total_passed + 1
        print("    PASS: " .. tostring(label))
    else
        total_failed = total_failed + 1
        local msg = tostring(label) .. " — expected non-nil, got nil"
        table.insert(total_errors, "[" .. current_suite .. "] " .. msg)
        print("    FAIL: " .. msg)
    end
end

function assert_nil(v, label)
    if v == nil then
        total_passed = total_passed + 1
        print("    PASS: " .. tostring(label))
    else
        total_failed = total_failed + 1
        local msg = tostring(label) .. " — expected nil, got " .. tostring(v)
        table.insert(total_errors, "[" .. current_suite .. "] " .. msg)
        print("    FAIL: " .. msg)
    end
end

-- ---------------------------------------------------------------------------
-- Suite runner
-- ---------------------------------------------------------------------------

local function run_suite(name, file)
    current_suite = name
    print("\n== " .. name .. " ==")
    local path = TESTS_DIR .. file
    local ok, err = pcall(dofile, path)
    if not ok then
        total_failed = total_failed + 1
        local msg = "suite crashed: " .. tostring(err)
        table.insert(total_errors, "[" .. name .. "] " .. msg)
        print("    ERROR: " .. msg)
    end
end

-- ---------------------------------------------------------------------------
-- Test suites
-- ---------------------------------------------------------------------------

run_suite("Library Sort",            "test_library_sort.lua")
run_suite("Wakeup Guard",            "test_wakeup_guard.lua")
run_suite("Unread Count Display",    "test_unread_count_display.lua")
run_suite("Continue Reading",        "test_continue_reading.lua")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed", total_passed, total_failed))

if #total_errors > 0 then
    print("\nFailed assertions:")
    for _, msg in ipairs(total_errors) do
        print("  • " .. msg)
    end
end

print(string.rep("=", 50))

if total_failed > 0 then
    -- Non-zero exit for CI / terminal detection
    os.exit(1)
end
