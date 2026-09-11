-- test_sync_queue.lua — Tests for mangasync.koplugin/sync_queue.lua
--
-- Strategy:
--   • Mock datastorage (required at module-load time) so QUEUE_FILE resolves to
--     a deterministic in-memory path.
--   • Replace io.open and os.rename with an in-memory virtual filesystem so the
--     queue never touches real storage.
--   • Provide Lua-5.1/5.2/5.3 compat shims: loadstring (removed in 5.3) and
--     setfenv (removed in 5.2).
--
-- Kindle constraint tested:
--   • FAT32 on some Kindle firmware does not support atomic rename.  When
--     os.rename fails the queue file must not be corrupted (the original content
--     must survive).
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_sync_queue.lua

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
-- Lua 5.1 / 5.2 / 5.3 compatibility shims
-- ---------------------------------------------------------------------------

-- loadstring was removed in Lua 5.3; load() handles strings in all versions.
if not loadstring then
    loadstring = load  -- luacheck: ignore
end

-- setfenv was removed in Lua 5.2.  The sync_queue module calls
-- setfenv(loader, {}) to sandbox the deserialized chunk. The queue content
-- contains only table literals with no global references, so a no-op shim is
-- sufficient for the data patterns this module generates.
if not setfenv then
    setfenv = function() end  -- luacheck: ignore
end

-- ---------------------------------------------------------------------------
-- Path resolution
-- ---------------------------------------------------------------------------

local function tests_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[/\\])") or "./"
end

local MODULE_PATH = tests_dir() .. "../../mangasync.koplugin/sync_queue.lua"

-- ---------------------------------------------------------------------------
-- Deterministic settings path so QUEUE_FILE is known
-- ---------------------------------------------------------------------------

local TEST_SETTINGS_DIR = "/test/mock/sync"
local QUEUE_FILE        = TEST_SETTINGS_DIR .. "/mangasync_queue.lua"
local QUEUE_TMP         = QUEUE_FILE .. ".tmp"

package.loaded["datastorage"] = nil
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function(self) return TEST_SETTINGS_DIR end,
    }
end

-- ---------------------------------------------------------------------------
-- In-memory virtual filesystem mocking io.open + os.rename
-- ---------------------------------------------------------------------------

local vfs = {}   -- { [path] = content_string }

local real_io_open   = io.open
local real_os_rename = os.rename
local real_os_time   = os.time

io.open = function(path, mode)
    if mode == "w" then
        local buf = {}
        return {
            write = function(self, data)  buf[#buf + 1] = data end,
            close = function(self) vfs[path] = table.concat(buf) end,
        }
    elseif mode == "r" then
        local content = vfs[path]
        if not content then return nil end
        local consumed = false
        return {
            read = function(self, n)
                if consumed then return nil end
                consumed = true
                if type(n) == "number" then
                    return content:sub(1, n)
                end
                return content
            end,
            close = function(self) end,
        }
    end
    return nil
end

os.rename = function(src, dst)
    if vfs[src] ~= nil then
        vfs[dst] = vfs[src]
        vfs[src] = nil
        return true
    end
    return nil, "no such file in vfs"
end

-- Reset the virtual filesystem between tests
local function reset_vfs()
    vfs = {}
end

-- ---------------------------------------------------------------------------
-- Load the module under test
-- ---------------------------------------------------------------------------

local SyncQueue = dofile(MODULE_PATH)

-- ===========================================================================
-- Test 1: enqueue adds an item; getCount reflects it; getAll returns it
-- ===========================================================================

do
    reset_vfs()
    local entry = { chapter_id = "ch1", last_page = 3, is_read = false, timestamp = 100 }
    local ok = SyncQueue.enqueue(entry)
    assert_true(ok, "enqueue: returns true on success")
    assert_eq(SyncQueue.getCount(), 1, "enqueue: getCount() is 1 after one enqueue")
    local all = SyncQueue.getAll()
    assert_eq(#all, 1, "enqueue: getAll() returns 1 entry")
    assert_eq(all[1].chapter_id, "ch1", "enqueue: correct chapter_id stored")
    assert_eq(all[1].last_page,  3,     "enqueue: correct last_page stored")
end

-- ===========================================================================
-- Test 2: enqueue deduplicates by chapter_id — updating an existing entry
--         does not grow the queue
-- ===========================================================================

do
    reset_vfs()
    SyncQueue.enqueue({ chapter_id = "ch1", last_page = 2, is_read = false, timestamp = 100 })
    SyncQueue.enqueue({ chapter_id = "ch1", last_page = 7, is_read = true,  timestamp = 200 })
    assert_eq(SyncQueue.getCount(), 1,
        "enqueue dedup: second enqueue of same chapter_id does not grow queue")
    local all = SyncQueue.getAll()
    assert_eq(all[1].last_page, 7,
        "enqueue dedup: updated entry has latest last_page")
    assert_eq(all[1].is_read, true,
        "enqueue dedup: updated entry has latest is_read")
end

-- ===========================================================================
-- Test 3: getAll returns all items; clear empties the queue completely
-- ===========================================================================

do
    reset_vfs()
    SyncQueue.enqueue({ chapter_id = "a", last_page = 0, is_read = false, timestamp = 1 })
    SyncQueue.enqueue({ chapter_id = "b", last_page = 0, is_read = false, timestamp = 2 })
    SyncQueue.enqueue({ chapter_id = "c", last_page = 0, is_read = false, timestamp = 3 })
    local all = SyncQueue.getAll()
    assert_eq(#all, 3, "getAll: returns all 3 enqueued entries")
    SyncQueue.clear()
    assert_eq(SyncQueue.getCount(), 0, "clear: getCount() is 0 after clear()")
    local after = SyncQueue.getAll()
    assert_eq(#after, 0, "clear: getAll() returns empty table after clear()")
end

-- ===========================================================================
-- Test 4: queue is bounded at 200 entries — oldest entry is dropped when full
-- ===========================================================================

do
    reset_vfs()
    -- Fill queue to capacity
    for i = 1, 200 do
        SyncQueue.enqueue({
            chapter_id = "cap_" .. tostring(i),
            last_page  = i,
            is_read    = false,
            timestamp  = i,
        })
    end
    assert_eq(SyncQueue.getCount(), 200, "queue cap: 200 entries fit exactly")

    -- The 201st entry should evict the oldest (cap_1)
    SyncQueue.enqueue({
        chapter_id = "cap_201",
        last_page  = 201,
        is_read    = false,
        timestamp  = 201,
    })
    assert_eq(SyncQueue.getCount(), 200,
        "queue cap: count stays at 200 after inserting 201st entry")
    local all = SyncQueue.getAll()
    -- First entry should now be cap_2 (cap_1 was oldest and was dropped)
    assert_eq(all[1].chapter_id, "cap_2",
        "queue cap: oldest entry (cap_1) was dropped to make room")
    assert_eq(all[200].chapter_id, "cap_201",
        "queue cap: newest entry (cap_201) is at the tail")
end

-- ===========================================================================
-- Test 5: replaceAll — remove a specific entry by filtering and re-writing
-- ===========================================================================

do
    reset_vfs()
    SyncQueue.enqueue({ chapter_id = "keep1", last_page = 1, is_read = false, timestamp = 1 })
    SyncQueue.enqueue({ chapter_id = "drop",  last_page = 2, is_read = false, timestamp = 2 })
    SyncQueue.enqueue({ chapter_id = "keep2", last_page = 3, is_read = false, timestamp = 3 })
    assert_eq(SyncQueue.getCount(), 3, "replaceAll setup: 3 entries")

    -- Simulate "remove by chapter_id" via getAll + filter + replaceAll
    local filtered = {}
    for _, entry in ipairs(SyncQueue.getAll()) do
        if entry.chapter_id ~= "drop" then
            filtered[#filtered + 1] = entry
        end
    end
    local ok = SyncQueue.replaceAll(filtered)
    assert_true(ok, "replaceAll: returns true")
    assert_eq(SyncQueue.getCount(), 2,
        "replaceAll: entry removed, count is 2")
    local after = SyncQueue.getAll()
    assert_eq(after[1].chapter_id, "keep1", "replaceAll: keep1 still present")
    assert_eq(after[2].chapter_id, "keep2", "replaceAll: keep2 still present")
end

-- ===========================================================================
-- Test 6: getCount returns correct count without loading the full queue
-- ===========================================================================

do
    reset_vfs()
    assert_eq(SyncQueue.getCount(), 0, "getCount: 0 on empty queue")
    SyncQueue.enqueue({ chapter_id = "x", last_page = 0, is_read = false, timestamp = 1 })
    assert_eq(SyncQueue.getCount(), 1, "getCount: 1 after one enqueue")
    SyncQueue.enqueue({ chapter_id = "y", last_page = 0, is_read = false, timestamp = 2 })
    assert_eq(SyncQueue.getCount(), 2, "getCount: 2 after second enqueue")
end

-- ===========================================================================
-- Test 7: serialization round-trip — enqueue → persist → read back via getAll
-- ===========================================================================

do
    reset_vfs()
    local original = { chapter_id = "rtrip-77", last_page = 12, is_read = true, timestamp = 999 }
    SyncQueue.enqueue(original)

    -- getAll re-reads from the virtual filesystem and deserializes
    local all = SyncQueue.getAll()
    assert_eq(#all, 1, "round-trip: one entry returned")
    assert_eq(all[1].chapter_id, "rtrip-77", "round-trip: chapter_id preserved")
    assert_eq(all[1].last_page,  12,          "round-trip: last_page preserved")
    assert_eq(all[1].is_read,    true,         "round-trip: is_read preserved")
    assert_eq(all[1].timestamp,  999,          "round-trip: timestamp preserved")
end

-- ===========================================================================
-- Test 8: Kindle constraint — os.rename failure leaves previous queue intact
--         (FAT32 atomic-rename can fail on some firmware; the .tmp file must
--         not overwrite the original if rename returns nil)
-- ===========================================================================

do
    reset_vfs()
    -- Seed a known queue state
    SyncQueue.enqueue({ chapter_id = "safe", last_page = 1, is_read = false, timestamp = 10 })
    -- Verify the queue file exists with the seeded data
    assert_eq(SyncQueue.getCount(), 1, "rename-failure setup: queue has 1 entry")

    -- Break os.rename so the next write cannot atomically commit
    local saved_rename = os.rename
    os.rename = function(src, dst) return nil, "permission denied" end

    -- Attempt to add another entry — the atomic commit will fail
    local ok = SyncQueue.enqueue({ chapter_id = "unsafe", last_page = 5, is_read = false, timestamp = 20 })
    assert_false(ok, "rename failure: enqueue returns false when rename fails")

    -- Restore os.rename and verify the original queue is still readable
    os.rename = saved_rename
    local count = SyncQueue.getCount()
    assert_eq(count, 1,
        "rename failure: original queue still has 1 entry (not corrupted)")
    local all = SyncQueue.getAll()
    assert_eq(all[1].chapter_id, "safe",
        "rename failure: original entry 'safe' still intact")
end

-- ===========================================================================
-- Test 9: enqueue rejects invalid input without crashing
-- ===========================================================================

do
    reset_vfs()
    assert_false(SyncQueue.enqueue(nil),
        "enqueue nil: returns false")
    assert_false(SyncQueue.enqueue("string"),
        "enqueue string: returns false")
    assert_false(SyncQueue.enqueue({ last_page = 1 }),  -- no chapter_id
        "enqueue missing chapter_id: returns false")
    assert_eq(SyncQueue.getCount(), 0,
        "enqueue invalid inputs: queue remains empty")
end

-- ===========================================================================
-- Teardown: restore real IO globals
-- ===========================================================================

io.open   = real_io_open
os.rename = real_os_rename
os.time   = real_os_time

if _standalone then
    print("\nSync Queue: see above for individual results")
end
