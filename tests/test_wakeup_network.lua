-- test_wakeup_network.lua — Integration test: WakeupGuard + transport retry
--
-- Tests the full lifecycle of the wakeup-guard state machine as it would play
-- out in a real plugin session (boot → first success → sleep → re-wakeup) and
-- verifies that a simulated retry loop respects the guard's parameters.
--
-- The guard is loaded fresh for each scenario via dofile so that the module-
-- level _last_successful_request_time starts at 0 each time.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_wakeup_network.lua

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
            print("    FAIL: " .. label
                .. " — expected " .. tostring(b) .. " got " .. tostring(a))
            table.insert(_e, label)
        end
    end
    assert_true  = function(v, l) assert_eq(not not v, true,  l) end
    assert_false = function(v, l) assert_eq(not not v, false, l) end
    assert_nil   = function(v, l) assert_eq(v, nil, l) end
    assert_not_nil = function(v, l)
        if v ~= nil then _p = _p + 1; print("    PASS: " .. l)
        else _f = _f + 1; print("    FAIL: " .. l .. " — expected non-nil")
            table.insert(_e, l) end
    end
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
-- os.time mock infrastructure (same pattern as test_wakeup_guard.lua)
-- ---------------------------------------------------------------------------

local real_os_time = os.time
local mock_time    = 0

local function set_time(t)
    mock_time = t
    os.time = function() return mock_time end
end

local function load_guard()
    return dofile(GUARD_PATH)
end

-- ---------------------------------------------------------------------------
-- Mock retry loop
-- Mirrors the retry logic a network transport would use with the guard.
-- Captures per-attempt delay configuration and the total number of attempts.
-- ---------------------------------------------------------------------------

local function run_retry_loop(guard, request_fn)
    local max_attempts = guard.getMaxRetries()
    local delay        = guard.getReconnectDelay()
    local delays_used  = {}
    local attempts     = 0

    for attempt = 1, max_attempts do
        attempts = attempt
        local ok = request_fn(attempt)
        if ok then
            guard.recordSuccess()
            return { success = true, attempts = attempts,
                     delays_used = delays_used, delay_config = delay }
        end
        if attempt < max_attempts then
            delays_used[#delays_used + 1] = delay
        end
    end
    return { success = false, attempts = attempts,
             delays_used = delays_used, delay_config = delay }
end

-- ===========================================================================
-- Scenario 1: Device boots (last_success = 0)
--   → isWakeup = true  → maxRetries = 5, delay = 4 s
-- ===========================================================================

do
    set_time(5000)
    local G = load_guard()
    assert_true(G.isWakeup(),
        "boot: isWakeup is true when device never connected (last_success=0)")
    assert_eq(G.getMaxRetries(),     5,
        "boot: getMaxRetries() = 5 in wakeup state")
    assert_eq(G.getReconnectDelay(), 4,
        "boot: getReconnectDelay() = 4 s in wakeup state")
end

-- ===========================================================================
-- Scenario 2: First successful request
--   → recordSuccess() → isWakeup = false → maxRetries = 3, delay = 1 s
-- ===========================================================================

do
    set_time(5000)
    local G = load_guard()
    G.recordSuccess()
    set_time(5001)   -- 1 s later
    assert_false(G.isWakeup(),
        "after first success: isWakeup is false (gap = 1 s < threshold)")
    assert_eq(G.getMaxRetries(),     3,
        "after first success: getMaxRetries() = 3 in normal state")
    assert_eq(G.getReconnectDelay(), 1,
        "after first success: getReconnectDelay() = 1 s in normal state")
end

-- ===========================================================================
-- Scenario 3: 35 seconds elapse after a successful request → wakeup again
-- ===========================================================================

do
    set_time(7000)
    local G = load_guard()
    G.recordSuccess()         -- recorded at 7000
    set_time(7035)            -- 35 s later > 30 s threshold
    assert_true(G.isWakeup(),
        "35 s silence: isWakeup becomes true again")
    assert_eq(G.getMaxRetries(),     5,
        "35 s silence: maxRetries reverts to 5")
    assert_eq(G.getReconnectDelay(), 4,
        "35 s silence: reconnect delay reverts to 4 s")
end

-- ===========================================================================
-- Scenario 4: Rapid succession of three successes → stays non-wakeup
-- ===========================================================================

do
    set_time(9000)
    local G = load_guard()
    G.recordSuccess(); set_time(9001)
    G.recordSuccess(); set_time(9002)
    G.recordSuccess(); set_time(9003)
    assert_false(G.isWakeup(),
        "rapid successes: isWakeup stays false after three quick recordSuccess calls")
    assert_eq(G.getMaxRetries(), 3,
        "rapid successes: maxRetries stays at 3")
end

-- ===========================================================================
-- Scenario 5: Edge — exactly 30 s gap is NOT a wakeup (condition is > 30)
-- ===========================================================================

do
    set_time(1000)
    local G = load_guard()
    G.recordSuccess()    -- recorded at 1000
    set_time(1030)       -- exactly 30 s: 1030 - 1000 = 30, NOT > 30
    assert_false(G.isWakeup(),
        "boundary: exactly 30 s gap is NOT a wakeup (> 30, not >= 30)")
    set_time(1031)       -- 31 s: 1031 - 1000 = 31, IS > 30
    assert_true(G.isWakeup(),
        "boundary: 31 s gap IS a wakeup")
end

-- ===========================================================================
-- Scenario 6a: Retry loop in wakeup state — always failing
--   All 5 attempts are exhausted; 4 inter-attempt delays are accumulated.
-- ===========================================================================

do
    set_time(2000)
    local G = load_guard()    -- _last_success = 0 → wakeup

    local result = run_retry_loop(G, function() return false end)

    assert_false(result.success,
        "retry loop wakeup: all attempts fail → success is false")
    assert_eq(result.attempts, 5,
        "retry loop wakeup: exhausts all 5 max attempts")
    assert_eq(result.delay_config, 4,
        "retry loop wakeup: configured delay is 4 s per gap")
    assert_eq(#result.delays_used, 4,
        "retry loop wakeup: 4 inter-attempt delays (one fewer than attempts)")
    -- Every delay must equal the wakeup delay constant
    local all_four = true
    for _, d in ipairs(result.delays_used) do
        if d ~= 4 then all_four = false end
    end
    assert_true(all_four,
        "retry loop wakeup: every inter-attempt delay is exactly 4 s")
end

-- ===========================================================================
-- Scenario 6b: Retry loop in normal state — succeeds on 2nd attempt
--   Only 1 inter-attempt delay; delay is 1 s (normal mode).
-- ===========================================================================

do
    set_time(3000)
    local G = load_guard()
    G.recordSuccess()    -- mark as connected at 3000
    set_time(3005)       -- 5 s later → normal mode

    local result = run_retry_loop(G, function(attempt) return attempt == 2 end)

    assert_true(result.success,
        "retry loop normal: succeeds on second attempt")
    assert_eq(result.attempts, 2,
        "retry loop normal: exactly 2 attempts made")
    assert_eq(result.delay_config, 1,
        "retry loop normal: configured delay is 1 s")
    assert_eq(#result.delays_used, 1,
        "retry loop normal: exactly 1 inter-attempt delay")
    assert_eq(result.delays_used[1], 1,
        "retry loop normal: inter-attempt delay is 1 s")
end

-- ===========================================================================
-- Scenario 6c: Retry loop in wakeup state — succeeds immediately (1 attempt)
--   No inter-attempt delays accumulated; recordSuccess is called.
-- ===========================================================================

do
    set_time(4000)
    local G = load_guard()   -- _last_success = 0 → wakeup

    local result = run_retry_loop(G, function() return true end)

    assert_true(result.success,
        "retry loop wakeup instant: succeeds on first attempt")
    assert_eq(result.attempts, 1,
        "retry loop wakeup instant: only 1 attempt made")
    assert_eq(#result.delays_used, 0,
        "retry loop wakeup instant: no inter-attempt delays needed")
    -- After recordSuccess the guard should leave wakeup mode
    set_time(4002)
    assert_false(G.isWakeup(),
        "retry loop wakeup instant: isWakeup false after recordSuccess in loop")
end

-- ---------------------------------------------------------------------------
-- Restore real os.time
-- ---------------------------------------------------------------------------

os.time = real_os_time

if _standalone then
    print("\nWakeup Network Integration: see above for individual results")
end
