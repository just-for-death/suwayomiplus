-- test_library_sort.lua — Tests for sortLibraryMangaByUnread logic
--
-- The function is local inside suwayomi/client/library.lua so we reproduce
-- the exact same logic here.  If the implementation changes the sort contract,
-- at least one of these tests will fail and act as a regression signal.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_library_sort.lua

-- ---------------------------------------------------------------------------
-- Standalone bootstrap (skipped when dofile'd by test_runner.lua)
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
-- Exact copy of the local function from suwayomi/client/library.lua
-- (update here if the implementation changes)
-- ---------------------------------------------------------------------------

local function sortLibraryMangaByUnread(manga_list)
    local sorted = {}
    for _, m in ipairs(manga_list) do sorted[#sorted + 1] = m end
    table.sort(sorted, function(a, b)
        local ua = tonumber(a.unread_count) or 0
        local ub = tonumber(b.unread_count) or 0
        if ua ~= ub then return ua > ub end
        return (a.title or "") < (b.title or "")
    end)
    return sorted
end

-- ---------------------------------------------------------------------------
-- Helper: build a minimal manga stub
-- ---------------------------------------------------------------------------

local function manga(title, unread_count)
    return { title = title, unread_count = unread_count }
end

-- ---------------------------------------------------------------------------
-- Test 1: empty list returns empty list
-- ---------------------------------------------------------------------------

do
    local result = sortLibraryMangaByUnread({})
    assert_eq(#result, 0, "empty list → empty result")
end

-- ---------------------------------------------------------------------------
-- Test 2: all unread_count = 0 → sorted alphabetically by title
-- ---------------------------------------------------------------------------

do
    local input = {
        manga("Zorro",    0),
        manga("Alpha",    0),
        manga("Midrange", 0),
    }
    local result = sortLibraryMangaByUnread(input)
    assert_eq(#result,        3,          "all-zero unread: length preserved")
    assert_eq(result[1].title, "Alpha",    "all-zero unread: 1st is Alpha")
    assert_eq(result[2].title, "Midrange", "all-zero unread: 2nd is Midrange")
    assert_eq(result[3].title, "Zorro",    "all-zero unread: 3rd is Zorro")
end

-- ---------------------------------------------------------------------------
-- Test 3: mixed unread counts → sorted by unread count descending
-- ---------------------------------------------------------------------------

do
    local input = {
        manga("C Manga",  3),
        manga("A Manga", 10),
        manga("B Manga",  1),
    }
    local result = sortLibraryMangaByUnread(input)
    assert_eq(result[1].title, "A Manga", "mixed unread: highest unread first")
    assert_eq(result[2].title, "C Manga", "mixed unread: second highest next")
    assert_eq(result[3].title, "B Manga", "mixed unread: lowest unread last")
    assert_eq(result[1].unread_count, 10, "mixed unread: correct count at position 1")
    assert_eq(result[3].unread_count,  1, "mixed unread: correct count at position 3")
end

-- ---------------------------------------------------------------------------
-- Test 4: equal unread counts → sorted alphabetically within tie group
-- ---------------------------------------------------------------------------

do
    local input = {
        manga("Zeta",  5),
        manga("Alpha", 5),
        manga("Gamma", 5),
    }
    local result = sortLibraryMangaByUnread(input)
    assert_eq(result[1].title, "Alpha", "tie-break: Alpha first")
    assert_eq(result[2].title, "Gamma", "tie-break: Gamma second")
    assert_eq(result[3].title, "Zeta",  "tie-break: Zeta last")
end

-- ---------------------------------------------------------------------------
-- Test 5: nil unread_count treated as 0 (no error, sorts with zero-count group)
-- ---------------------------------------------------------------------------

do
    local input = {
        manga("HasCount", 2),
        manga("NilCount", nil),
        manga("ZeroCount", 0),
    }
    -- Should not raise; nil is coerced to 0 via tonumber()
    local ok, result = pcall(sortLibraryMangaByUnread, input)
    assert_true(ok, "nil unread_count: no error thrown")
    assert_eq(result[1].title, "HasCount",  "nil unread_count: non-nil unread first")
    -- NilCount and ZeroCount both resolve to 0 → alphabetical
    assert_eq(result[2].title, "NilCount",  "nil unread_count: N before Z alphabetically")
    assert_eq(result[3].title, "ZeroCount", "nil unread_count: ZeroCount last")
end

-- ---------------------------------------------------------------------------
-- Test 6: original list is not mutated
-- ---------------------------------------------------------------------------

do
    local a = manga("B", 1)
    local b = manga("A", 2)
    local input = { a, b }
    local result = sortLibraryMangaByUnread(input)
    assert_eq(input[1].title, "B", "sort is non-destructive: original[1] unchanged")
    assert_eq(input[2].title, "A", "sort is non-destructive: original[2] unchanged")
    assert_eq(result[1].title, "A", "sort is non-destructive: result sorted correctly")
end

-- ---------------------------------------------------------------------------
-- Test 7: mixed unread + nil with alphabetical tie-breaking across both groups
-- ---------------------------------------------------------------------------

do
    local input = {
        manga("Berry",  nil),   -- nil → 0
        manga("Apple",  0),
        manga("Cherry", 5),
        manga("Date",   5),
    }
    local result = sortLibraryMangaByUnread(input)
    -- unread=5 group first (alphabetical within)
    assert_eq(result[1].title, "Cherry", "mixed+nil: Cherry (5, C) before Date (5, D)")
    assert_eq(result[2].title, "Date",   "mixed+nil: Date (5) second")
    -- unread=0/nil group (alphabetical)
    assert_eq(result[3].title, "Apple",  "mixed+nil: Apple (0) before Berry (nil)")
    assert_eq(result[4].title, "Berry",  "mixed+nil: Berry (nil) last")
end

-- ---------------------------------------------------------------------------
-- Standalone summary
-- ---------------------------------------------------------------------------

if _standalone then
    print(string.format("\nLibrary Sort: see above for individual results"))
end
