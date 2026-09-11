-- test_settings_defaults.lua — Tests for suwayomi/settings.lua defaults
--
-- Strategy:
--   The settings module requires datastorage, luasettings, and
--   suwayomi/source_filters.  We mock all three via package.preload so the
--   module can be loaded via dofile without the full KOReader runtime.
--   LuaSettings is mocked as an in-memory store so load* functions can be
--   tested end-to-end with realistic "no stored settings" behaviour.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_settings_defaults.lua

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

local MODULE_PATH = tests_dir() .. "../suwayomi/settings.lua"

-- ---------------------------------------------------------------------------
-- Mock: datastorage
-- settings.lua accesses DataStorage:getSettingsDir() at module-load time to
-- build the settings_file path.
-- ---------------------------------------------------------------------------

local old_ds_preload = package.preload["datastorage"]
local old_ds_loaded  = package.loaded["datastorage"]

package.loaded["datastorage"]  = nil
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function(self) return "/tmp/test_suwayomi" end,
    }
end

-- ---------------------------------------------------------------------------
-- Mock: luasettings
-- The in-memory store starts empty so readSetting always returns its default.
-- We also expose the store so tests can pre-seed values when needed.
-- ---------------------------------------------------------------------------

local old_ls_preload = package.preload["luasettings"]
local old_ls_loaded  = package.loaded["luasettings"]

local mock_store = {}  -- { [key] = value }

package.loaded["luasettings"]  = nil
package.preload["luasettings"] = function()
    local LS = {}
    LS.__index = LS
    function LS:open(path)
        return setmetatable({ _path = path }, LS)
    end
    function LS:readSetting(key, default)
        local v = mock_store[key]
        if v ~= nil then return v end
        return default
    end
    function LS:saveSetting(key, value)
        mock_store[key] = value
        return self
    end
    function LS:flush()
        return self
    end
    return LS
end

-- ---------------------------------------------------------------------------
-- Mock: suwayomi/source_filters
-- Only normalizeDraft is called; a minimal stub is sufficient.
-- ---------------------------------------------------------------------------

local old_sf_preload = package.preload["suwayomi/source_filters"]
local old_sf_loaded  = package.loaded["suwayomi/source_filters"]

package.loaded["suwayomi/source_filters"]  = nil
package.preload["suwayomi/source_filters"] = function()
    return {
        normalizeDraft = function(draft)
            if type(draft) == "table" then return draft end
            return { query = "", filters = {} }
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Load module under test
-- ---------------------------------------------------------------------------

local S = dofile(MODULE_PATH)

-- Helper: reset the in-memory settings store between tests
local function reset_store()
    mock_store = {}
    -- LuaSettings is already loaded; the store table is captured by closure
    -- in the mock, so replacing it requires updating the upvalue reference.
    -- Simpler: the open() mock accesses mock_store through the module closure,
    -- so clearing mock_store works if we use the same table.  Use table.clear
    -- if available, otherwise iterate.
    for k in pairs(mock_store) do mock_store[k] = nil end
    -- Reset cached settings handle so open() re-reads from mock_store
    S.settings = nil
end

-- ===========================================================================
-- Test 1: Default chapter_tap_action = "quick_view" (online stream, not DL)
-- ===========================================================================

do
    reset_store()
    local action = S:loadChapterTapAction()
    assert_eq(action, "quick_view",
        "default chapter_tap_action: 'quick_view' (online-first stream)")
end

-- ===========================================================================
-- Test 2: normalizeChapterTapAction — valid values pass through unchanged
-- ===========================================================================

do
    assert_eq(S:normalizeChapterTapAction("quick_view"), "quick_view",
        "normalizeChapterTapAction: 'quick_view' is valid")
    assert_eq(S:normalizeChapterTapAction("reader"), "reader",
        "normalizeChapterTapAction: 'reader' is valid")
end

-- ===========================================================================
-- Test 3: normalizeChapterTapAction — invalid value falls back to default
-- ===========================================================================

do
    assert_eq(S:normalizeChapterTapAction("download"), "quick_view",
        "normalizeChapterTapAction: unknown 'download' → 'quick_view'")
    assert_eq(S:normalizeChapterTapAction(nil), "quick_view",
        "normalizeChapterTapAction: nil → 'quick_view'")
    assert_eq(S:normalizeChapterTapAction(42), "quick_view",
        "normalizeChapterTapAction: number → 'quick_view'")
end

-- ===========================================================================
-- Test 4: Default max_parallel_chapter_downloads = 1 (sane, within 1–4 range)
-- ===========================================================================

do
    reset_store()
    local n = S:loadMaxParallelChapterDownloads()
    assert_true(type(n) == "number",
        "default max_parallel_downloads: is a number")
    assert_true(n >= 1 and n <= 4,
        "default max_parallel_downloads: within sane 1–4 range")
    assert_eq(n, 1,
        "default max_parallel_downloads: default is 1 (conservative)")
end

-- ===========================================================================
-- Test 5: normalizeMaxParallelChapterDownloads clamps to 1–4
-- ===========================================================================

do
    assert_eq(S:normalizeMaxParallelChapterDownloads(0), 1,
        "clamp downloads: 0 clamped to minimum 1")
    assert_eq(S:normalizeMaxParallelChapterDownloads(-5), 1,
        "clamp downloads: negative clamped to minimum 1")
    assert_eq(S:normalizeMaxParallelChapterDownloads(5), 4,
        "clamp downloads: 5 clamped to maximum 4")
    assert_eq(S:normalizeMaxParallelChapterDownloads(100), 4,
        "clamp downloads: 100 clamped to maximum 4")
    assert_eq(S:normalizeMaxParallelChapterDownloads(2), 2,
        "clamp downloads: 2 is valid, returned unchanged")
    assert_eq(S:normalizeMaxParallelChapterDownloads(nil), 1,
        "clamp downloads: nil → default 1")
end

-- ===========================================================================
-- Test 6: normalizeMaxParallelChapterDownloads floors floats
-- ===========================================================================

do
    assert_eq(S:normalizeMaxParallelChapterDownloads(2.9), 2,
        "clamp downloads: 2.9 floored to 2")
    assert_eq(S:normalizeMaxParallelChapterDownloads(1.1), 1,
        "clamp downloads: 1.1 floored to 1")
end

-- ===========================================================================
-- Test 7: getDefaultDownloadDirectory contains "Manga" (case check)
--         The hardcoded default on Kindle is /mnt/us/Books/Manga.
-- ===========================================================================

do
    local dir = S:getDefaultDownloadDirectory()
    assert_not_nil(dir, "default download directory: non-nil")
    assert_true(type(dir) == "string", "default download directory: is a string")
    assert_true(dir:lower():find("manga") ~= nil,
        "default download directory: contains 'manga' for proper organization")
end

-- ===========================================================================
-- Test 8: loadDownloadDirectory with no stored setting → returns default
--         (which contains "Manga")
-- ===========================================================================

do
    reset_store()
    local dir = S:loadDownloadDirectory()
    assert_not_nil(dir, "loadDownloadDirectory no setting: non-nil")
    assert_true(type(dir) == "string",
        "loadDownloadDirectory no setting: is a string")
    assert_true(dir:lower():find("manga") ~= nil,
        "loadDownloadDirectory no setting: default contains 'manga'")
end

-- ===========================================================================
-- Test 9: normalizeChapterCacheLimitMB — default is 500 (positive number)
-- ===========================================================================

do
    local limit = S:normalizeChapterCacheLimitMB(nil)
    assert_true(type(limit) == "number", "default cache limit: is a number")
    assert_true(limit > 0, "default cache limit: positive number")
    assert_eq(limit, 500, "default cache limit: default is 500 MB")
end

-- ===========================================================================
-- Test 10: normalizeChapterCacheLimitMB — invalid value → 500 default
-- ===========================================================================

do
    assert_eq(S:normalizeChapterCacheLimitMB(999), 500,
        "normalizeChapterCacheLimitMB: 999 not in choices → 500 default")
    assert_eq(S:normalizeChapterCacheLimitMB(0), 500,
        "normalizeChapterCacheLimitMB: 0 not in choices → 500 default")
    assert_eq(S:normalizeChapterCacheLimitMB("hello"), 500,
        "normalizeChapterCacheLimitMB: non-number string → 500 default")
end

-- ===========================================================================
-- Test 11: normalizeChapterCacheLimitMB — valid choices pass through
-- ===========================================================================

do
    assert_eq(S:normalizeChapterCacheLimitMB(100),  100,
        "normalizeChapterCacheLimitMB: 100 MB is valid")
    assert_eq(S:normalizeChapterCacheLimitMB(250),  250,
        "normalizeChapterCacheLimitMB: 250 MB is valid")
    assert_eq(S:normalizeChapterCacheLimitMB(1000), 1000,
        "normalizeChapterCacheLimitMB: 1000 MB is valid")
    assert_eq(S:normalizeChapterCacheLimitMB(2000), 2000,
        "normalizeChapterCacheLimitMB: 2000 MB is valid")
end

-- ===========================================================================
-- Test 12: loadChapterCacheLimitMB with no stored value → returns 500
-- ===========================================================================

do
    reset_store()
    local limit = S:loadChapterCacheLimitMB()
    assert_eq(limit, 500,
        "loadChapterCacheLimitMB no setting: default is 500 MB")
    assert_true(limit > 0,
        "loadChapterCacheLimitMB no setting: result is positive")
end

-- ===========================================================================
-- Test 13: normalizeMaxParallelChapterDownloads is consistent with
--          loadMaxParallelChapterDownloads default
-- ===========================================================================

do
    reset_store()
    local loaded    = S:loadMaxParallelChapterDownloads()
    local normalized = S:normalizeMaxParallelChapterDownloads(nil)
    assert_eq(loaded, normalized,
        "consistency: loadMaxParallelChapterDownloads() == normalizeMaxParallelChapterDownloads(nil)")
end

-- ---------------------------------------------------------------------------
-- Teardown: restore package state
-- ---------------------------------------------------------------------------

package.preload["datastorage"]           = old_ds_preload
package.loaded["datastorage"]            = old_ds_loaded
package.preload["luasettings"]           = old_ls_preload
package.loaded["luasettings"]            = old_ls_loaded
package.preload["suwayomi/source_filters"] = old_sf_preload
package.loaded["suwayomi/source_filters"]  = old_sf_loaded

if _standalone then
    print("\nSettings Defaults: see above for individual results")
end
