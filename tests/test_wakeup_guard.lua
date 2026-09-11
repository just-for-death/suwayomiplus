-- test_wakeup_guard.lua — Tests for suwayomi/network/wakeup_guard.lua
--
-- Strategy: replace os.time with a controllable mock before loading the module
-- via dofile.  Because wakeup_guard.lua resolves os.time at call-time (not at
-- load-time), every call to WakeupGuard.isWakeup / recordSuccess uses whatever
-- os.time currently returns.
--
-- Each test scenario gets a fresh module instance (fresh dofile) so that the
-- module-level _last_successful_request_time always starts at 0.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_wakeup_guard.lua

-- ---------------------------------------------------------------------------
-- Standalone bootstrap
-- ---------------------------------------------------------------------------

local _standalone = type(assert_eq) ~= "function"
if _standalone then
    local _p, _f, _e = 0, 0, {}
    assert_eq = function(a, b, label)
        if a == b then _p = _p + 1; print("    PASS: " .. label)
        else
            _f = _f + 1
            print("    FAIL: " .. label .. " — expected " .. tostring(b) .. " got " .. tostring(a))
            table.insert(_e, label)
        end
    end
    assert_true  = function(v, l) assert_eq(not not v, true,  l) end
    assert_false = function(v, l) assert_eq(not not v, false, l) end
end

-- ---------------------------------------------------------------------------
-- Path resolution
-- ---------------------------------------------------------------------------

local function tests_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[/\\])") or "./"
end

local GUARD_PATH = tests_dir() .. "../suwayomi/network/wakeup_guard.lua"

-- ---------------------------------------------------------------------------
-- os.time mock infrastructure
-- ---------------------------------------------------------------------------

local real_os_time = os.time  -- saved so we can restore after all tests
local mock_time = 0

local function set_time(t)
    mock_time = t
    os.time = function() return mock_time end
end

-- Fresh module load: each call gives a new WakeupGuard table with
-- _last_successful_request_time reset to 0.
local function load_guard()
    return dofile(GUARD_PATH)
end

-- ---------------------------------------------------------------------------
-- Test 1: isWakeup() returns true when the device has never successfully
--         connected (_last_successful_request_time starts at 0, threshold = 30s)
-- ---------------------------------------------------------------------------

do
    set_time(1000)  -- 1000 - 0 = 1000 > 30 → wakeup
    local G = load_guard()
    assert_true(G.isWakeup(), "isWakeup: true when never connected (time far from epoch)")
end

-- ---------------------------------------------------------------------------
-- Test 2: isWakeup() returns false immediately after recordSuccess()
-- ---------------------------------------------------------------------------

do
    set_time(5000)
    local G = load_guard()
    G.recordSuccess()           -- _last_successful_request_time = 5000
    set_time(5002)              -- only 2 s gap → not a wakeup
    assert_false(G.isWakeup(), "isWakeup: false just after recordSuccess (2 s gap)")
end

-- ---------------------------------------------------------------------------
-- Test 3: getMaxRetries() returns 5 when in wakeup state
-- ---------------------------------------------------------------------------

do
    set_time(9999)
    local G = load_guard()     -- _last_successful_request_time = 0 → wakeup
    assert_true(G.isWakeup(),  "getMaxRetries/wakeup: precondition — isWakeup is true")
    assert_eq(G.getMaxRetries(), 5, "getMaxRetries: 5 in wakeup state")
end

-- ---------------------------------------------------------------------------
-- Test 4: getReconnectDelay() returns 4 when in wakeup state
-- ---------------------------------------------------------------------------

do
    set_time(9999)
    local G = load_guard()
    assert_true(G.isWakeup(),  "getReconnectDelay/wakeup: precondition — isWakeup is true")
    assert_eq(G.getReconnectDelay(), 4, "getReconnectDelay: 4 in wakeup state")
end

-- ---------------------------------------------------------------------------
-- Test 5: getMaxRetries() returns 3 in normal (non-wakeup) state
-- ---------------------------------------------------------------------------

do
    set_time(2000)
    local G = load_guard()
    G.recordSuccess()           -- recorded at 2000
    set_time(2010)              -- 10 s later → not a wakeup
    assert_false(G.isWakeup(), "getMaxRetries/normal: precondition — isWakeup is false")
    assert_eq(G.getMaxRetries(), 3, "getMaxRetries: 3 in normal state")
end

-- ---------------------------------------------------------------------------
-- Test 6: getReconnectDelay() returns 1 in normal (non-wakeup) state
-- ---------------------------------------------------------------------------

do
    set_time(3000)
    local G = load_guard()
    G.recordSuccess()           -- recorded at 3000
    set_time(3015)              -- 15 s later → not a wakeup
    assert_false(G.isWakeup(), "getReconnectDelay/normal: precondition — isWakeup is false")
    assert_eq(G.getReconnectDelay(), 1, "getReconnectDelay: 1 in normal state")
end

-- ---------------------------------------------------------------------------
-- Test 7: recordSuccess() then advancing past threshold → isWakeup becomes true
--         (simulates the device sleeping after a successful request)
-- ---------------------------------------------------------------------------

do
    set_time(7000)
    local G = load_guard()
    G.recordSuccess()           -- recorded at 7000
    set_time(7031)              -- 31 s later — past the 30 s threshold
    assert_true(G.isWakeup(),  "isWakeup: true after 31 s of silence post-success")
    -- …and retry parameters reflect wakeup mode
    assert_eq(G.getMaxRetries(),      5, "getMaxRetries: 5 after silence exceeds threshold")
    assert_eq(G.getReconnectDelay(),  4, "getReconnectDelay: 4 after silence exceeds threshold")
end

-- ---------------------------------------------------------------------------
-- Test 8: exactly at the threshold boundary (== 30) is NOT a wakeup
--         because the condition is strictly > 30
-- ---------------------------------------------------------------------------

do
    set_time(8000)
    local G = load_guard()
    G.recordSuccess()
    set_time(8030)              -- exactly 30 s → 30 > 30 is false
    assert_false(G.isWakeup(), "isWakeup: false at exactly 30 s (boundary: > 30, not >=)")
end

-- ---------------------------------------------------------------------------
-- Restore real os.time
-- ---------------------------------------------------------------------------

os.time = real_os_time

if _standalone then
    print("\nWakeup Guard: see above for individual results")
end
