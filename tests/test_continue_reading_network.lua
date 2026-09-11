-- test_continue_reading_network.lua — Tests for Continue Reading network error
-- handling logic from suwayomi/plugin/continue_reading.lua
--
-- Strategy:
--   The on_finish callback inside ContinueReadingController:continueReading()
--   contains all the interesting control-flow (error display, empty-history
--   branch, cancellation guard, manga selection, malformed-data handling).
--   We reproduce that callback verbatim as a standalone function and drive it
--   with a small controller stub, so the tests run without the KOReader UI
--   stack.
--
-- KNOWN BUG fixed in continue_reading.lua:
--   When result.entries is a non-table, ipairs must not be called on it.
--   Guard: type(result.entries) == "table" and result.entries or {}
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_continue_reading_network.lua

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
-- Verbatim extraction of the on_finish callback from
-- ContinueReadingController:continueReading() in
-- suwayomi/plugin/continue_reading.lua
--
-- Keep this in sync with the source file.  The I18n.t() calls are inlined as
-- plain strings because the strings themselves are part of the contract.
-- ---------------------------------------------------------------------------

local function makeOnFinishCallback(self_obj, token)
    return function(result)
        -- Cancellation guard: if the active request token has changed, this
        -- callback is stale and should not act.
        if self_obj.active_continue_reading_request ~= token then
            return
        end
        self_obj.active_continue_reading_request = nil

        if not result or not result.ok then
            self_obj.showMessage(
                (result and result.error) or "Could not load reading history."
            )
            return
        end

        local target_manga
        for _, entry in ipairs(type(result.entries) == "table" and result.entries or {}) do
            local manga = entry.manga
            if manga then
                local has_unread = manga.first_unread_chapter ~= nil
                    or (type(manga.unread_count) == "number" and manga.unread_count > 0)
                if has_unread then
                    target_manga = manga
                    break
                end
            end
        end

        if not target_manga then
            self_obj.showMessage("You're all caught up!")
            return
        end

        self_obj.resumeMangaStream(target_manga)
    end
end

-- ---------------------------------------------------------------------------
-- Minimal controller stub: captures side-effects for assertion
-- ---------------------------------------------------------------------------

local function makeController()
    local c = {
        active_continue_reading_request = nil,
        last_message  = nil,
        resumed_manga = nil,
    }
    c.showMessage       = function(msg)   c.last_message  = msg   end
    c.resumeMangaStream = function(manga) c.resumed_manga = manga  end
    return c
end

-- Convenience: set up controller + active token, build callback, invoke it.
local function invoke(result, cancelled)
    local ctrl  = makeController()
    local token = {}
    ctrl.active_continue_reading_request = token
    local cb = makeOnFinishCallback(ctrl, token)
    if cancelled then
        -- Simulate cancel: swap in a different token before callback fires
        ctrl.active_continue_reading_request = {}
    end
    local ok, err = pcall(cb, result)
    return ctrl, ok, err
end

-- ---------------------------------------------------------------------------
-- Helpers: build mock history shapes
-- ---------------------------------------------------------------------------

local function make_manga_with_unread(title, count)
    return { title = title, unread_count = count,
             first_unread_chapter = { id = 1, name = "Ch" } }
end

local function make_manga_all_read(title)
    return { title = title, unread_count = 0 }
end

local function make_entry(manga)
    return { manga = manga }
end

-- ===========================================================================
-- Test 1: Network timeout — {ok=false, error="timeout"}
--         → shows the error string, does not resume
-- ===========================================================================

do
    local ctrl, ok = invoke({ ok = false, error = "timeout" })
    assert_true(ok, "network timeout: callback does not crash")
    assert_eq(ctrl.last_message, "timeout",
        "network timeout: error string forwarded to showMessage")
    assert_nil(ctrl.resumed_manga,
        "network timeout: no manga resumed")
end

-- ===========================================================================
-- Test 2: ok=false with no error field → shows generic fallback message
-- ===========================================================================

do
    local ctrl, ok = invoke({ ok = false })
    assert_true(ok, "no error field: no crash")
    assert_eq(ctrl.last_message, "Could not load reading history.",
        "no error field: generic fallback message shown")
    assert_nil(ctrl.resumed_manga, "no error field: no manga resumed")
end

-- ===========================================================================
-- Test 3: nil result (transport returned nothing) → generic fallback
-- ===========================================================================

do
    local ctrl, ok = invoke(nil)
    assert_true(ok, "nil result: no crash")
    assert_eq(ctrl.last_message, "Could not load reading history.",
        "nil result: generic fallback message shown")
end

-- ===========================================================================
-- Test 4: Empty server — {ok=true, entries={}} → "You're all caught up!"
-- ===========================================================================

do
    local ctrl, ok = invoke({ ok = true, entries = {} })
    assert_true(ok, "empty entries: no crash")
    assert_eq(ctrl.last_message, "You're all caught up!",
        "empty entries: 'all caught up' message shown")
    assert_nil(ctrl.resumed_manga, "empty entries: no manga resumed")
end

-- ===========================================================================
-- Test 5: All entries read (no unread chapters) → "You're all caught up!"
-- ===========================================================================

do
    local result = {
        ok = true,
        entries = {
            make_entry(make_manga_all_read("Manga A")),
            make_entry(make_manga_all_read("Manga B")),
        },
    }
    local ctrl, ok = invoke(result)
    assert_true(ok, "all read: no crash")
    assert_eq(ctrl.last_message, "You're all caught up!",
        "all read: 'all caught up' message shown")
    assert_nil(ctrl.resumed_manga, "all read: no manga resumed")
end

-- ===========================================================================
-- Test 6: First entry has unread → immediately selected, no further checking
-- ===========================================================================

do
    local manga_a = make_manga_with_unread("First Manga", 3)
    local manga_b = make_manga_with_unread("Second Manga", 5)  -- more unread
    local result = {
        ok = true,
        entries = { make_entry(manga_a), make_entry(manga_b) },
    }
    local ctrl, ok = invoke(result)
    assert_true(ok, "first unread: no crash")
    assert_not_nil(ctrl.resumed_manga,
        "first unread: a manga was resumed")
    assert_eq(ctrl.resumed_manga.title, "First Manga",
        "first unread: FIRST eligible manga selected, not highest-unread")
    assert_nil(ctrl.last_message,
        "first unread: no error/caught-up message shown")
end

-- ===========================================================================
-- Test 7: Cancel mid-fetch — stale callback token → no side-effects
-- ===========================================================================

do
    local manga = make_manga_with_unread("Manga", 5)
    local result = { ok = true, entries = { make_entry(manga) } }
    local ctrl, ok = invoke(result, true)   -- cancelled = true
    assert_true(ok, "stale callback: no crash")
    assert_nil(ctrl.last_message,
        "stale callback: no message shown (request was cancelled)")
    assert_nil(ctrl.resumed_manga,
        "stale callback: no manga resumed (request was cancelled)")
end

-- ===========================================================================
-- Test 8: entries field present but nil manga inside entry → skipped silently
-- ===========================================================================

do
    local result = {
        ok = true,
        entries = {
            { manga = nil },   -- malformed: no manga
            make_entry(make_manga_with_unread("Good Manga", 2)),
        },
    }
    local ctrl, ok = invoke(result)
    assert_true(ok, "nil manga entry: no crash")
    assert_not_nil(ctrl.resumed_manga,
        "nil manga entry: second valid entry still selected")
    assert_eq(ctrl.resumed_manga.title, "Good Manga",
        "nil manga entry: correct manga selected after skipping nil entry")
end

-- ===========================================================================
-- Test 9: entries is a non-table (string) — behaviour is Lua-version-dependent.
--   Lua 5.1 / LuaJIT (KOReader runtime): ipairs throws on non-table → crash.
--   Lua 5.2+: ipairs queries __index, finds no integer keys → 0 iterations,
--             no crash.  Either way no manga is resumed.
-- ===========================================================================

do
    local result = { ok = true, entries = "not-a-table" }
    local ctrl, ok = invoke(result)
    -- On Lua 5.1/LuaJIT (real Kindle runtime) this would fail (ok=false).
    -- On Lua 5.2+ this passes.  Documented here so the Kindle runtime
    -- discrepancy is visible when the test suite is ported.
    assert_true(ok,
        "malformed entries string: no crash (type(entries)=='table' guard)")
    assert_nil(ctrl.resumed_manga,
        "malformed entries string: no manga resumed")
end

-- ===========================================================================
-- Test 10: unread_count > 0 alone (no first_unread_chapter) qualifies
-- ===========================================================================

do
    local manga = { title = "Partial Info", unread_count = 7 }  -- no first_unread_chapter
    local result = { ok = true, entries = { make_entry(manga) } }
    local ctrl, ok = invoke(result)
    assert_true(ok, "unread_count only: no crash")
    assert_not_nil(ctrl.resumed_manga,
        "unread_count only: manga resumed even without first_unread_chapter")
    assert_eq(ctrl.resumed_manga.title, "Partial Info",
        "unread_count only: correct manga selected")
end

-- ===========================================================================
-- Test 11: first_unread_chapter alone (unread_count = 0) qualifies
-- ===========================================================================

do
    local manga = { title = "Chapter Signalled",
                    unread_count = 0,
                    first_unread_chapter = { id = 99, name = "Ch 99" } }
    local result = { ok = true, entries = { make_entry(manga) } }
    local ctrl, ok = invoke(result)
    assert_true(ok, "first_unread_chapter alone: no crash")
    assert_not_nil(ctrl.resumed_manga,
        "first_unread_chapter alone: manga resumed")
    assert_eq(ctrl.resumed_manga.title, "Chapter Signalled",
        "first_unread_chapter alone: correct manga selected")
end

if _standalone then
    print("\nContinue Reading Network: see above for individual results")
end
