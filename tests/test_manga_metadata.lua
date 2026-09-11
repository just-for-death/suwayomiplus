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
    _mode     = {},      -- { [path] = "directory" | "file" } for paths that "exist"
    _dir      = {},      -- { [dir_path] = { name1, name2, ... } } for lfs.dir
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
        dir = function(path)
            local names = mock_lfs._dir[path] or {}
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Mock: io.open — captures writes, serves reads from an in-memory file map
-- ---------------------------------------------------------------------------

local real_io_open = io.open
local io_cap = { path = nil, content = nil }
local FILES = {}   -- in-memory filesystem for reads: [path] = raw content
local WROTE = {}   -- every written file: [path] = final content

io.open = function(path, mode)
    if mode == "r" or mode == "rb" then
        local content = FILES[path]
        if content == nil then return nil end
        return {
            read = function(self, fmt)
                return content
            end,
            close = function(self) end,
        }
    end
    if mode == "w" or mode == "wb" then
        local buf = {}
        return {
            write = function(self, ...)
                for i = 1, select("#", ...) do
                    buf[#buf + 1] = tostring(select(i, ...))
                end
            end,
            close = function(self)
                local text = table.concat(buf)
                io_cap.path    = path
                io_cap.content = text
                WROTE[path]    = text
            end,
        }
    end
    return nil  -- unsupported modes
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
    mock_lfs._dir   = {}
    mock_lfs.mkdir_ok = true
    io_cap.path    = nil
    io_cap.content = nil
    FILES = {}
    WROTE = {}
end

-- ---------------------------------------------------------------------------
-- Load the module under test (once; it has no module-level state)
-- ---------------------------------------------------------------------------

local MangaMetadata = dofile(MODULE_PATH)

-- ===========================================================================
-- Test 1: writeChapterMetadata produces chapter-only title for book model
--         "Ch. 1 - Chapter Name" with series = manga title
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga", author = "Author" }
    local chapter = { id = "c1", name = "Chapter Name", chapter_number = 1 }
    local ok = MangaMetadata.writeChapterMetadata("/manga/Ch1.cbz", manga, chapter)
    assert_true(ok, "writeChapterMetadata: returns true on success")
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "writeChapterMetadata: written content is valid Lua")
    assert_eq(meta.doc_props.title, "Ch. 1 - Chapter Name",
        "doc_props.title: chapter-only title (manga lives in series)")
    assert_eq(meta.doc_props.series, "My Manga",
        "doc_props.series: manga title is the book/series name")
end

-- ===========================================================================
-- Test 2: decimal chapter_number (1.5) → "Ch. 1.5 - Special"
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga" }
    local chapter = { id = "c2", name = "Special", chapter_number = 1.5 }
    MangaMetadata.writeChapterMetadata("/manga/Ch1.5.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "decimal chapter: written content is valid Lua")
    assert_eq(meta.doc_props.title, "Ch. 1.5 - Special",
        "doc_props.title: decimal chapter_number formatted cleanly")
end

-- ===========================================================================
-- Test 3: nil chapter_number → falls back to chapter name only
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga" }
    local chapter = { id = "c3", name = "Prologue" }  -- no chapter_number field
    MangaMetadata.writeChapterMetadata("/manga/Prologue.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "nil chapter_number: written content is valid Lua")
    assert_eq(meta.doc_props.title, "Prologue",
        "doc_props.title: nil chapter_number → chapter name only")
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
-- Test 7: sdr path matches KOReader DocSettings (strip last suffix + .sdr)
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "M" }
    local chapter = { id = "c8", name = "Chapter 1", chapter_number = 1 }
    local cbz_path = "/manga/Chapter 1.cbz"
    MangaMetadata.writeChapterMetadata(cbz_path, manga, chapter)
    local expected_meta_path = "/manga/Chapter 1.sdr/metadata.cbz.lua"
    assert_eq(io_cap.path, expected_meta_path,
        "sdr path: metadata written to <base>.sdr/metadata.cbz.lua (KOReader style)")
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
-- Test 13: fresh downloads pre-seed Manga Reading Mode (Fix 2)
--          fit-to-page zoom, RTL paging, no webtoon-like vertical scroll
-- ===========================================================================

do
    reset()
    local manga   = { id = "m1", title = "My Manga" }
    local chapter = { id = "c13", name = "Ch 1", chapter_number = 1 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "reading mode pre-seed: valid Lua")
    assert_eq(meta.zoom_mode, "page",
        "reading mode pre-seed: zoom_mode = 'page' (fit whole page)")
    assert_eq(meta.normal_zoom_mode, "page",
        "reading mode pre-seed: normal_zoom_mode = 'page'")
    assert_eq(meta.inverse_reading_order, true,
        "reading mode pre-seed: inverse_reading_order = true (RTL manga paging)")
    assert_eq(meta.kopt_page_scroll, 0,
        "reading mode pre-seed: kopt_page_scroll = 0 (no continuous vertical scroll)")
    assert_eq(meta.flipping_scroll_mode, false,
        "reading mode pre-seed: flipping_scroll_mode = false")
end

-- ===========================================================================
-- Test 14: an existing NON-nil user value is preserved by writeChapterMetadata
--          (pre-seed only fills nil, so a user tweak survives metadata rewrites)
-- ===========================================================================

do
    reset()
    mock_lfs._mode["/manga"] = "directory"
    FILES["/manga/Ch.sdr/metadata.cbz.lua"] = [[return {
        ["doc_props"] = { title = "Ch 1", series = "My Manga", series_index = 1 },
        ["zoom_mode"] = "container",
        ["inverse_reading_order"] = false,
        ["suwayomi_chapter_id"] = "c14",
        ["suwayomi_manga_id"] = "m1",
    }]]
    local manga   = { id = "m1", title = "My Manga" }
    local chapter = { id = "c14", name = "Ch 1", chapter_number = 1 }
    MangaMetadata.writeChapterMetadata("/manga/Ch.cbz", manga, chapter)
    local meta = load_content(io_cap.content)
    assert_not_nil(meta, "preserve user values: valid Lua")
    assert_eq(meta.zoom_mode, "container",
        "preserve user values: existing zoom_mode not overwritten by pre-seed")
    assert_eq(meta.inverse_reading_order, false,
        "preserve user values: existing inverse_reading_order not overwritten")
    assert_eq(meta.normal_zoom_mode, "page",
        "preserve user values: missing normal_zoom_mode still pre-seeded to page")
end

-- ===========================================================================
-- Test 15: normalizeReadingMode migrates a legacy "contentwidth" sidecar
--          (Fix 3 core: replace zoom, enable RTL, clear fractional positions)
-- ===========================================================================

do
    local legacy = {
        zoom_mode             = "contentwidth",
        normal_zoom_mode      = "contentwidth",
        inverse_reading_order = false,
        kopt_page_scroll      = 1,
        flipping_scroll_mode  = true,
        page_positions        = { 0.875, 0.766 },
    }
    local migrated = MangaMetadata.normalizeReadingMode(legacy)
    assert_eq(migrated, legacy, "normalizeReadingMode mutates and returns the same table")
    assert_eq(migrated.zoom_mode, "page",
        "normalizeReadingMode: contentwidth zoom → page")
    assert_eq(migrated.normal_zoom_mode, "page",
        "normalizeReadingMode: normal_zoom_mode contentwidth → page")
    assert_eq(migrated.inverse_reading_order, true,
        "normalizeReadingMode: inverse_reading_order forced true")
    assert_eq(migrated.kopt_page_scroll, 0,
        "normalizeReadingMode: kopt_page_scroll forced 0")
    assert_eq(migrated.flipping_scroll_mode, false,
        "normalizeReadingMode: flipping_scroll_mode forced false")
    assert_eq(#migrated.page_positions, 0,
        "normalizeReadingMode: fractional page_positions cleared")
    assert_nil(MangaMetadata.normalizeReadingMode(nil),
        "normalizeReadingMode: nil input returns nil without crash")
end

-- ===========================================================================
-- Test 16: repairMangaDirectory batch-migrates an existing legacy chapter
--          (Fix 3 path: one call re-seeds + force-normalizes all chapters)
-- ===========================================================================

do
    reset()
    mock_lfs._mode = {
        ["/manga"]                  = "directory",
        ["/manga/Book One"]         = "directory",
        ["/manga/Book One/Ch. 1.cbz"] = "file",
    }
    mock_lfs._dir["/manga/Book One"] = { "Ch. 1.cbz" }
    FILES["/manga/Book One/Ch. 1.sdr/metadata.cbz.lua"] = [[return {
        ["doc_props"] = {
            ["title"] = "Ch. 1", ["series"] = "Book One", ["series_index"] = 1,
        },
        ["zoom_mode"] = "contentwidth",
        ["normal_zoom_mode"] = "contentwidth",
        ["inverse_reading_order"] = false,
        ["kopt_page_scroll"] = 1,
        ["flipping_scroll_mode"] = true,
        ["page_positions"] = { 0.875, 0.766 },
        ["suwayomi_chapter_id"] = "c1",
        ["suwayomi_manga_id"] = "m1",
    }]]

    local ok = MangaMetadata.repairMangaDirectory("/manga/Book One", { title = "Book One" })
    assert_true(ok, "repairMangaDirectory: returns true for a legacy chapter folder")

    local sidecar = WROTE["/manga/Book One/Ch. 1.sdr/metadata.cbz.lua"]
    assert_not_nil(sidecar, "repairMangaDirectory: sidecar was rewritten")
    local meta = load_content(sidecar)
    assert_not_nil(meta, "repairMangaDirectory: rewritten sidecar is valid Lua")
    assert_eq(meta.zoom_mode, "page",
        "repair migration: legacy contentwidth zoom → page")
    assert_eq(meta.normal_zoom_mode, "page",
        "repair migration: normal_zoom_mode contentwidth → page")
    assert_eq(meta.inverse_reading_order, true,
        "repair migration: inverse_reading_order enabled")
    assert_eq(meta.kopt_page_scroll, 0,
        "repair migration: kopt_page_scroll reset to 0")
    assert_eq(meta.flipping_scroll_mode, false,
        "repair migration: flipping_scroll_mode disabled")
    assert_eq(#meta.page_positions, 0,
        "repair migration: fractional page_positions cleared")
    assert_eq(meta.suwayomi_chapter_id, "c1",
        "repair migration: chapter ID still present after rewrite")
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
