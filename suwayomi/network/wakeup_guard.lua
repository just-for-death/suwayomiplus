-- Boundary: sleep/wakeup reconnect guard.
--
-- Responsibility: track the timestamp of the last successful API response and
-- expose retry parameters that are relaxed when the device appears to have
-- just woken from sleep (e.g. after a Tailscale reconnect delay).
-- Owned state: module-level last-success timestamp only.
-- Dependencies: os.time only.

local WakeupGuard = {}

local _last_successful_request_time = 0

-- Seconds of silence that suggest the device was asleep.
local WAKEUP_THRESHOLD_SECONDS = 30
-- Inter-attempt delay when in wakeup mode (seconds).
local WAKEUP_RECONNECT_DELAY = 4
-- Inter-attempt delay during normal operation (seconds).
local NORMAL_RECONNECT_DELAY = 1
-- Maximum retry attempts when in wakeup mode.
local WAKEUP_MAX_RETRIES = 5
-- Maximum retry attempts during normal operation.
local NORMAL_MAX_RETRIES = 3

-- Called after every successful API response so future calls can judge elapsed
-- time accurately.
function WakeupGuard.recordSuccess()
    _last_successful_request_time = os.time()
end

-- Returns true when the gap since the last successful response is long enough
-- to suggest the device was suspended (e.g. Kindle sleep / Tailscale drop).
function WakeupGuard.isWakeup()
    return os.time() - _last_successful_request_time > WAKEUP_THRESHOLD_SECONDS
end

-- Seconds to wait between connection-error retries.
function WakeupGuard.getReconnectDelay()
    if WakeupGuard.isWakeup() then
        return WAKEUP_RECONNECT_DELAY
    end
    return NORMAL_RECONNECT_DELAY
end

-- Total number of attempts to make before giving up on a retryable connection
-- error.  Includes the first attempt, so the real retry count is this minus 1.
function WakeupGuard.getMaxRetries()
    if WakeupGuard.isWakeup() then
        return WAKEUP_MAX_RETRIES
    end
    return NORMAL_MAX_RETRIES
end

return WakeupGuard
