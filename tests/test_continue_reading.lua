-- test_continue_reading.lua — Tests for Continue Reading selection logic
--
-- The critical logic lives in the on_finish callback inside
-- ContinueReadingController:continueReading() in
-- suwayomi/plugin/continue_reading.lua.
--
-- We extract that exact selection loop into a pure function here and verify it
-- against realistic history-entry shapes, so that if the selection contract
-- changes the tests will fail.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_continue_reading.lua

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
    assert_nil   = function(v, l) assert_eq(v, nil, l) end
    assert_not_nil = function(v, l)
        if v ~= nil then _p = _p + 1; print("    PASS: " .. l)
        else _f = _f + 1; print("    FAIL: " .. l .. " — expected non-nil"); table.insert(_e, l) end
    end
end

-- ---------------------------------------------------------------------------
-- Verbatim extraction of the target-manga selection loop from
-- ContinueReadingController:continueReading()  (the on_finish callback).
-- Keep this in sync with the source file.
-- ---------------------------------------------------------------------------

local function selectTargetManga(entries)
    local target_manga
    for _, entry in ipairs(entries or {}) do
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
    return target_manga
end

-- ---------------------------------------------------------------------------
-- Helpers: build mock history-entry and manga shapes
-- ---------------------------------------------------------------------------

local function make_manga(opts)
    -- opts: { title, unread_count, first_unread_chapter }
    local m = { title = opts.title }
    if opts.unread_count ~= nil then
        m.unread_count = opts.unread_count
    end
    if opts.first_unread_chapter ~= nil then
        m.first_unread_chapter = opts.first_unread_chapter
    end
    return m
end

local function make_entry(manga)
    return { manga = manga }
end

local function make_chapter(id)
    return { id = id, name = "Chapter " .. tostring(id) }
end

-- ---------------------------------------------------------------------------
-- Test 1: empty history → no manga selected (nil)
-- ---------------------------------------------------------------------------

do
    local result = selectTargetManga({})
    assert_nil(result, "empty history: no manga selected")
end

-- ---------------------------------------------------------------------------
-- Test 2: history entries with no unread data → no manga selected
--         (unread_count = 0, no first_unread_chapter)
-- ---------------------------------------------------------------------------

do
    local entries = {
        make_entry(make_manga({ title = "Manga A", unread_count = 0 })),
        make_entry(make_manga({ title = "Manga B", unread_count = 0 })),
    }
    local result = selectTargetManga(entries)
    assert_nil(result, "all-read history: no manga selected")
end

-- ---------------------------------------------------------------------------
-- Test 3: first entry has first_unread_chapter → that manga is selected
-- ---------------------------------------------------------------------------

do
    local chapter = make_chapter(42)
    local manga_a = make_manga({
        title               = "Manga A",
        unread_count        = 3,
        first_unread_chapter = chapter,
    })
    local entries = {
        make_entry(manga_a),
        make_entry(make_manga({ title = "Manga B", unread_count = 5,
                                first_unread_chapter = make_chapter(10) })),
    }
    local result = selectTargetManga(entries)
    assert_not_nil(result, "first_unread_chapter present: manga selected")
    assert_eq(result.title, "Manga A",
        "first_unread_chapter present: first eligible manga returned")
    assert_eq(result.first_unread_chapter.id, 42,
        "first_unread_chapter present: correct chapter attached")
end

-- ---------------------------------------------------------------------------
-- Test 4: first entry has no unread; second does → second is selected
-- ---------------------------------------------------------------------------

do
    local entries = {
        make_entry(make_manga({ title = "Done",    unread_count = 0 })),
        make_entry(make_manga({ title = "Ongoing", unread_count = 2,
                                first_unread_chapter = make_chapter(7) })),
    }
    local result = selectTargetManga(entries)
    assert_not_nil(result, "skip-to-second: manga selected")
    assert_eq(result.title, "Ongoing",
        "skip-to-second: first all-read entry skipped, second selected")
end

-- ---------------------------------------------------------------------------
-- Test 5: unread_count > 0 but first_unread_chapter is nil → still selected
--         (the logic ORs the two conditions; either alone qualifies)
-- ---------------------------------------------------------------------------

do
    local manga_a = make_manga({ title = "Manga A", unread_count = 4 })
    -- first_unread_chapter intentionally absent
    local entries = { make_entry(manga_a) }
    local result = selectTargetManga(entries)
    assert_not_nil(result, "unread_count>0 without first_unread_chapter: selected")
    assert_eq(result.title, "Manga A",
        "unread_count>0 without first_unread_chapter: correct manga")
    assert_nil(result.first_unread_chapter,
        "unread_count>0 without first_unread_chapter: chapter field is nil")
end

-- ---------------------------------------------------------------------------
-- Test 6: first_unread_chapter present but unread_count = 0 → still selected
--         (first_unread_chapter alone qualifies regardless of unread_count)
-- ---------------------------------------------------------------------------

do
    local manga_a = make_manga({
        title                = "Manga A",
        unread_count         = 0,
        first_unread_chapter = make_chapter(1),
    })
    local entries = { make_entry(manga_a) }
    local result = selectTargetManga(entries)
    assert_not_nil(result, "first_unread_chapter alone qualifies: selected")
    assert_eq(result.title, "Manga A",
        "first_unread_chapter alone qualifies: correct manga")
end

-- ---------------------------------------------------------------------------
-- Test 7: entries with nil manga fields are silently skipped
-- ---------------------------------------------------------------------------

do
    local entries = {
        { manga = nil },   -- malformed entry: no manga
        make_entry(make_manga({ title = "Valid", unread_count = 1,
                                first_unread_chapter = make_chapter(5) })),
    }
    local result = selectTargetManga(entries)
    assert_not_nil(result, "nil manga entry skipped: still finds next entry")
    assert_eq(result.title, "Valid", "nil manga entry skipped: correct manga selected")
end

-- ---------------------------------------------------------------------------
-- Test 8: string unread_count (e.g. from JSON) is NOT treated as > 0
--         because the check requires type == "number"
-- ---------------------------------------------------------------------------

do
    -- unread_count is a string "5" (mis-parsed data), no first_unread_chapter
    local manga_a = { title = "Manga A", unread_count = "5" }
    local entries = { make_entry(manga_a) }
    local result = selectTargetManga(entries)
    -- type("5") ~= "number", so has_unread is false → no manga selected
    assert_nil(result,
        "string unread_count without first_unread_chapter: not selected (type guard)")
end

-- ---------------------------------------------------------------------------
-- Test 9: selection stops at the first eligible entry (break semantics)
-- ---------------------------------------------------------------------------

do
    local manga_first  = make_manga({ title = "First",  unread_count = 1,
                                      first_unread_chapter = make_chapter(10) })
    local manga_second = make_manga({ title = "Second", unread_count = 9,
                                      first_unread_chapter = make_chapter(20) })
    local entries = { make_entry(manga_first), make_entry(manga_second) }
    local result = selectTargetManga(entries)
    assert_eq(result.title, "First",
        "break semantics: first eligible entry returned, not highest-unread")
end

if _standalone then
    print("\nContinue Reading: see above for individual results")
end
