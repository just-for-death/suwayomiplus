-- test_manga_metadata.lua — Tests for suwayomi/downloads/manga_metadata.lua
--
-- Strategy:
--   • Mock suwayomi/fs (the lfs wrapper) via package.preload so ensureDirectory
--     can succeed or fail under our control.
--   • Replace io.open with a capture mock so we never touch the real filesystem.
--   • Load the actual module via dofile so that source-level changes break tests.
--   • Parse captured Lua output with load/loadstring to extract field values.
--
-- Kindle constraint tested:
--   • lfs.mkdir failure (common on FAT32 /mnt/us due to permission issues) must
--     be handled gracefully — no crash, returns false.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_manga_metadata.lua

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

local MODULE_PATH = tests_dir() .. "../suwayomi/downloads/manga_metadata.lua"

-- ---------------------------------------------------------------------------
-- Mock: suwayomi/fs (lfs wrapper)
-- State is shared mutable so individual tests can flip mkdir_ok.
-- ---------------------------------------------------------------------------

local mock_lfs = {
    _mode     = {},      -- { [path] = "directory" } for paths that "exist"
    mkdir_ok  = true,    -- controls whether mkdir succeeds
}

-- Clear any previously loaded version so our preload is used.
package.loaded["suwayomi/fs"] = nil
package.preload["suwayomi/fs"] = function()
    return {
        attributes = function(path, attr)
            if attr == "mode" then
                return mock_lfs._mode[path]
            end
            return nil
        end,
        mkdir = function(path)
            if mock_lfs.mkdir_ok then
                mock_lfs._mode[path] = "directory"
                return true
            end
            return nil   -- simulate FAT32 permission failure
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Mock: io.open — captures writes, returns nil for reads
-- ---------------------------------------------------------------------------

local real_io_open = io.open
local io_cap = { path = nil, content = nil }

io.open = function(path, mode)
    if mode == "w" then
        local buf = {}
        return {
            write = function(self, data) buf[#buf + 1] = data end,
            close = function(self)
                io_cap.path    = path
                io_cap.content = table.concat(buf)
            end,
        }
    end
    return nil  -- no reads needed for these tests
end

-- ---------------------------------------------------------------------------
-- Helper: parse a captured Lua chunk back into a table
-- ---------------------------------------------------------------------------

local function load_content(text)
    if not text then return nil end
    local fn = (loadstring or load)(text)
    if not fn then return nil end
    local ok, result = pcall(fn)
    return ok and result or nil
end

-- ---------------------------------------------------------------------------
-- Helper: reset shared state between tests
-- ---------------------------------------------------------------------------

local function reset()
    mock_lfs._mode  = { ["/manga"] = "directory" }   -- manga dir pre-exists
    mock_lfs.mkdir_ok = true
    io_cap.path    = nil
    io_cap.content = nil
end

-- ---------------------------------------------------------------------------
-- Load the module under test (once; it has no module-level state)
-- ---------------------------------------------------------------------------

local MangaMetadata = dofile(MODULE_PATH)

-- ===========================================================================
-- Test 1: writeChapterMetadata produces the correct doc_props.title format
--         "Ch. 00001.0 - Chapter Name" for chapter_number = 1
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga", author = "Author" }
    local chapter = { id = "c1", name = "Chapter Name", chapter_number = 1 }
    local ok = MangaMetadata.writeChapterMetadata("/manga/Ch1.cbz", manga, chapter)
    assert_true(ok, "writeChapterMetadata: returns true on success")
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "writeChapterMetadata: written content is valid Lua")
    assert_eq(meta.doc_props.title, "Ch. 001.0 - Chapter Name",
        "doc_props.title: integer chapter_number → %05.1f format (width=5) with .0 suffix")
end

-- ===========================================================================
-- Test 2: decimal chapter_number (1.5) → "Ch. 00001.5 - Special"
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga" }
    local chapter = { id = "c2", name = "Special", chapter_number = 1.5 }
    MangaMetadata.writeChapterMetadata("/manga/Ch1.5.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "decimal chapter: written content is valid Lua")
    assert_eq(meta.doc_props.title, "Ch. 001.5 - Special",
        "doc_props.title: decimal chapter_number formatted correctly (%05.1f width=5)")
end

-- ===========================================================================
-- Test 3: nil chapter_number → falls back to chapter.name verbatim
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga" }
    local chapter = { id = "c3", name = "Prologue" }  -- no chapter_number field
    MangaMetadata.writeChapterMetadata("/manga/Prologue.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "nil chapter_number: written content is valid Lua")
    assert_eq(meta.doc_props.title, "Prologue",
        "doc_props.title: nil chapter_number → chapter.name verbatim")
end

-- ===========================================================================
-- Test 4a: author and artist are different → combined as "Author, Artist"
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "M", author = "Writer", artist = "Drawer" }
    local chapter = { id = "c4", name = "Ch", chapter_number = 1 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "author+artist combined: valid Lua")
    assert_eq(meta.doc_props.authors, "Writer, Drawer",
        "doc_props.authors: different author and artist combined with ', '")
end

-- ===========================================================================
-- Test 4b: author and artist are the SAME → no duplication
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "M", author = "Solo", artist = "Solo" }
    local chapter = { id = "c5", name = "Ch", chapter_number = 1 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "author==artist: valid Lua")
    assert_eq(meta.doc_props.authors, "Solo",
        "doc_props.authors: same author and artist not duplicated")
end

-- ===========================================================================
-- Test 5: series field = manga.title
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "Dragon Ball Z" }
    local chapter = { id = "c6", name = "Ch 1", chapter_number = 1 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "series field: valid Lua")
    assert_eq(meta.doc_props.series, "Dragon Ball Z",
        "doc_props.series = manga.title")
end

-- ===========================================================================
-- Test 6: series_index = chapter_number as number
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "M" }
    local chapter = { id = "c7", name = "Ch", chapter_number = 42 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "series_index: valid Lua")
    assert_eq(meta.doc_props.series_index, 42,
        "doc_props.series_index = chapter_number as number (42)")
end

-- ===========================================================================
-- Test 7: sdr path is path .. ".sdr/metadata.cbz.lua"
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "M" }
    local chapter = { id = "c8", name = "Chapter 1", chapter_number = 1 }
    local cbz_path = "/manga/Chapter 1.cbz"
    MangaMetadata.writeChapterMetadata(cbz_path, manga, chapter)
    local expected_meta_path = cbz_path .. ".sdr/metadata.cbz.lua"
    assert_eq(io_cap.path, expected_meta_path,
        "sdr path: metadata written to <cbz>.sdr/metadata.cbz.lua")
end

-- ===========================================================================
-- Test 8: writeMangaIndex sorts chapters by source_order
-- ===========================================================================

do
    reset()
    local manga = { id = "m1", title = "M" }
    local chapters = {
        { chapter = { id = "c3", name = "Ch3", chapter_number = 3, source_order = 30 }, path = "/m/c3.cbz" },
        { chapter = { id = "c1", name = "Ch1", chapter_number = 1, source_order = 10 }, path = "/m/c1.cbz" },
        { chapter = { id = "c2", name = "Ch2", chapter_number = 2, source_order = 20 }, path = "/m/c2.cbz" },
    }
    local ok = MangaMetadata.writeMangaIndex("/manga", manga, chapters)
    assert_true(ok, "writeMangaIndex: returns true")
    local idx = load_content(io_cap.content)
    assert_not_nil(idx, "writeMangaIndex sort by source_order: valid Lua")
    assert_eq(idx.chapters[1].id, "c1",
        "sort by source_order: first chapter is source_order=10 (c1)")
    assert_eq(idx.chapters[2].id, "c2",
        "sort by source_order: second chapter is source_order=20 (c2)")
    assert_eq(idx.chapters[3].id, "c3",
        "sort by source_order: third chapter is source_order=30 (c3)")
end

-- ===========================================================================
-- Test 9: writeMangaIndex falls back to chapter_number when source_order absent
-- ===========================================================================

do
    reset()
    local manga = { id = "m1", title = "M" }
    local chapters = {
        { chapter = { id = "cx", name = "ChX", chapter_number = 5 }, path = "/m/cx.cbz" },
        { chapter = { id = "ca", name = "ChA", chapter_number = 1 }, path = "/m/ca.cbz" },
        { chapter = { id = "cm", name = "ChM", chapter_number = 3 }, path = "/m/cm.cbz" },
    }
    MangaMetadata.writeMangaIndex("/manga", manga, chapters)
    local idx = load_content(io_cap.content)
    assert_not_nil(idx, "writeMangaIndex sort by chapter_number: valid Lua")
    assert_eq(idx.chapters[1].id, "ca",
        "sort by chapter_number: chapter_number=1 first")
    assert_eq(idx.chapters[2].id, "cm",
        "sort by chapter_number: chapter_number=3 second")
    assert_eq(idx.chapters[3].id, "cx",
        "sort by chapter_number: chapter_number=5 third")
end

-- ===========================================================================
-- Test 10: chapter ID and manga ID are embedded in the metadata for MangaSync
-- ===========================================================================

do
    reset()
    local manga   = { id = "manga-99", title = "M" }
    local chapter = { id = "chap-42",  name = "Ch", chapter_number = 1 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "embedded IDs: valid Lua")
    assert_eq(meta.suwayomi_chapter_id, "chap-42",
        "suwayomi_chapter_id written correctly for MangaSync lookup")
    assert_eq(meta.suwayomi_manga_id, "manga-99",
        "suwayomi_manga_id written correctly for MangaSync lookup")
end

-- ===========================================================================
-- Test 11: Kindle constraint — lfs.mkdir failure handled gracefully
--          (FAT32 /mnt/us returns permission errors on some firmware versions)
-- ===========================================================================

do
    -- No directories pre-exist, and mkdir always fails
    mock_lfs._mode   = {}
    mock_lfs.mkdir_ok = false
    io_cap.path      = nil
    io_cap.content   = nil

    local manga   = { id = "m1", title = "M" }
    local chapter = { id = "c9", name = "Ch", chapter_number = 1 }
    local ok = MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    assert_false(ok, "lfs.mkdir failure: writeChapterMetadata returns false")
    assert_nil(io_cap.content,
        "lfs.mkdir failure: no write attempted after ensureDirectory fails")
end

-- ===========================================================================
-- Test 12: empty path argument → returns false immediately, no crash
-- ===========================================================================

do
    reset()
    local ok = MangaMetadata.writeChapterMetadata("", {}, {})
    assert_false(ok, "empty path: writeChapterMetadata returns false without crash")
end

-- ===========================================================================
-- Teardown: restore real io.open
-- ===========================================================================

io.open = real_io_open
-- Leave package.preload/loaded for suwayomi/fs set — it's harmless and consistent
-- with how KOReader loads modules in sequence.

if _standalone then
    print("\nManga Metadata: see above for individual results")
end
