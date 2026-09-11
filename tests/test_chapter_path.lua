-- test_chapter_path.lua — Tests for suwayomi/paths.lua
--
-- Strategy:
--   • Mock ffi/util (FFIUtil.joinPath) via package.preload with a simple but
--     correct path-join implementation so the module can be loaded via dofile
--     without the full KOReader runtime.
--   • Test each public function against realistic inputs and edge cases.
--
-- Kindle constraint tested:
--   • Kindle's FAT32 filesystem enforces NAME_MAX = 255 bytes per path
--     component (bytes, not characters; UTF-8 multi-byte chars count more).
--     KNOWN BUG: sanitizePathSegment does not truncate — tests below document
--     this deficiency so it shows as a failing assertion (real bug report).
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_chapter_path.lua

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

local MODULE_PATH = tests_dir() .. "../suwayomi/paths.lua"

-- ---------------------------------------------------------------------------
-- Mock ffi/util
-- Provides a correct joinPath that matches KOReader's joinPath contract:
--   • Concatenate with "/" as separator
--   • Preserve a leading "/" on the first segment
--   • Collapse runs of consecutive "/" to a single "/"
-- ---------------------------------------------------------------------------

local old_ffi_util_preload = package.preload["ffi/util"]
local old_ffi_util_loaded  = package.loaded["ffi/util"]

package.loaded["ffi/util"]  = nil  -- ensure our preload runs
package.preload["ffi/util"] = function()
    return {
        joinPath = function(...)
            local result = ""
            for _, segment in ipairs({...}) do
                segment = tostring(segment or "")
                if segment ~= "" then
                    if result == "" then
                        result = segment
                    else
                        -- Strip trailing slash from result and leading slash from segment
                        -- to avoid double slashes, then join.
                        local r = result:gsub("/+$", "")
                        local s = segment:gsub("^/+", "")
                        result = r .. "/" .. s
                    end
                end
            end
            return result
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Load the module under test
-- ---------------------------------------------------------------------------

local SuwayomiPaths = dofile(MODULE_PATH)

-- ===========================================================================
-- Test 1: basic path construction: download_dir / source / manga / chapter.cbz
-- ===========================================================================

do
    local manga = {
        title  = "My Manga",
        source = { displayName = "MangaDex" },
    }
    local chapter = { id = "42", name = "Chapter 1", chapter_number = 1 }
    local path = SuwayomiPaths.getChapterPath("/mnt/us/Books/Manga", manga, chapter)
    assert_not_nil(path, "basic path: non-nil result")
    -- Path must start with the download directory
    assert_true(path:sub(1, #"/mnt/us/Books/Manga") == "/mnt/us/Books/Manga",
        "basic path: starts with download directory")
    -- Must contain the source label
    assert_true(path:find("MangaDex", 1, true) ~= nil,
        "basic path: source directory present in path")
    -- Must contain the manga title
    assert_true(path:find("My Manga", 1, true) ~= nil,
        "basic path: manga title directory present in path")
    -- Must end with .cbz
    assert_true(path:sub(-4) == ".cbz",
        "basic path: path ends with .cbz")
end

-- ===========================================================================
-- Test 2: manga title with slashes and colons is sanitized (→ underscore)
-- ===========================================================================

do
    local manga = {
        title  = "Attack on Titan: The Final Season / Arc 2",
        source = { displayName = "Src" },
    }
    local chapter = { id = "1", name = "Ch1" }
    local path = SuwayomiPaths.getChapterPath("/dl", manga, chapter)
    assert_not_nil(path, "special chars in title: path is non-nil")
    assert_true(path:find("/", #"/dl/" + 1, true) == nil
                or not path:find("Attack on Titan: The Final Season / Arc 2", 1, true),
        "special chars in title: original slashes/colons NOT present verbatim in path")
    assert_true(path:find("Attack on Titan_ The Final Season _ Arc 2", 1, true) ~= nil,
        "special chars in title: slash and colon replaced by underscore in manga dir")
end

-- ===========================================================================
-- Test 3: sanitizePathSegment replaces all forbidden chars with underscore
-- ===========================================================================

do
    -- FAT32 / Kindle-forbidden chars: \ / : * ? " < > |
    local forbidden = 'name\\with:all*of?"the<bad>chars|here'
    local sanitized = SuwayomiPaths.sanitizePathSegment(forbidden)
    -- None of the forbidden characters should remain
    assert_false(sanitized:find('[\\/:*?"<>|]') ~= nil,
        "sanitize: forbidden chars removed from segment")
    -- Only underscores should replace them
    assert_true(sanitized:find("_") ~= nil,
        "sanitize: underscores used as replacement")
end

-- ===========================================================================
-- Test 4: sanitizePathSegment — empty / dot / dotdot → "untitled"
-- ===========================================================================

do
    assert_eq(SuwayomiPaths.sanitizePathSegment(""),   "untitled",
        "sanitize empty string: returns 'untitled'")
    assert_eq(SuwayomiPaths.sanitizePathSegment("."),  "untitled",
        "sanitize dot: returns 'untitled'")
    assert_eq(SuwayomiPaths.sanitizePathSegment(".."), "untitled",
        "sanitize dotdot: returns 'untitled'")
end

-- ===========================================================================
-- Test 5: sanitizePathSegment strips leading/trailing whitespace
-- ===========================================================================

do
    local result = SuwayomiPaths.sanitizePathSegment("  My Manga  ")
    assert_eq(result, "My Manga",
        "sanitize whitespace: leading/trailing whitespace stripped")
end

-- ===========================================================================
-- Test 6: Unicode titles (Japanese/Chinese) pass through without error
-- ===========================================================================

do
    local unicode_title = "進撃の巨人"   -- "Attack on Titan" in Japanese
    local manga   = { title = unicode_title, source = { displayName = "JP Source" } }
    local chapter = { id = "1", name = "第1話" }  -- "Episode 1" in Japanese
    local ok, path = pcall(SuwayomiPaths.getChapterPath, "/dl", manga, chapter)
    assert_true(ok,  "unicode title: no error during path construction")
    assert_not_nil(path, "unicode title: path is non-nil")
    -- The Japanese title bytes should appear in the path
    assert_true(type(path) == "string", "unicode title: result is a string")
end

-- ===========================================================================
-- Test 7: no double slashes in constructed path
-- ===========================================================================

do
    local manga   = { title = "M", source = { displayName = "S" } }
    local chapter = { id = "1", name = "Ch" }
    local path = SuwayomiPaths.getChapterPath("/mnt/us/Books/Manga", manga, chapter)
    assert_false(path:find("//") ~= nil,
        "no double slashes: path contains no consecutive slashes")
end

-- ===========================================================================
-- Test 8: path is relative to the configured download directory
-- ===========================================================================

do
    local manga   = { title = "M", source = { displayName = "S" } }
    local chapter = { id = "1", name = "Ch" }
    local dl1 = "/mnt/us/Books/Manga"
    local dl2 = "/sdcard/Manga"
    local p1 = SuwayomiPaths.getChapterPath(dl1, manga, chapter)
    local p2 = SuwayomiPaths.getChapterPath(dl2, manga, chapter)
    assert_true(p1:sub(1, #dl1) == dl1,
        "download dir respected: path 1 starts with dl1")
    assert_true(p2:sub(1, #dl2) == dl2,
        "download dir respected: path 2 starts with dl2")
    assert_false(p1 == p2,
        "download dir respected: different download dirs produce different paths")
end

-- ===========================================================================
-- Test 9: nil/empty download directory → getMangaDirectory returns nil
-- ===========================================================================

do
    local manga = { title = "M", source = { displayName = "S" } }
    assert_nil(SuwayomiPaths.getMangaDirectory(nil, manga),
        "nil download dir: getMangaDirectory returns nil")
    assert_nil(SuwayomiPaths.getMangaDirectory("", manga),
        "empty download dir: getMangaDirectory returns nil")
end

-- ===========================================================================
-- Test 10: getChapterFilenames uses book-like "Ch. NNN - Name [id]" primary
--          and keeps plain/legacy names as fallback candidates
-- ===========================================================================

do
    local chapter = { id = "999", name = "Chapter 5", chapter_number = 5, source_order = 50 }
    local names = SuwayomiPaths.getChapterFilenames(chapter)
    assert_true(#names >= 2, "getChapterFilenames: at least 2 candidates returned")
    -- Primary book-like filename sorts in the manga folder.
    assert_true(names[1]:find("Ch. 005", 1, true) ~= nil,
        "getChapterFilenames: primary filename starts with Ch. 005")
    assert_true(names[1]:find("[id-999]", 1, true) ~= nil,
        "getChapterFilenames: id-based filename is first candidate")
    -- The plain name without ID must also be present
    local has_plain = false
    for _, name in ipairs(names) do
        if name == "Chapter 5.cbz" then has_plain = true end
    end
    assert_true(has_plain,
        "getChapterFilenames: plain 'Chapter 5.cbz' present as fallback candidate")
end

-- ===========================================================================
-- Test 11: Kindle constraint — very long ASCII manga title (> 255 bytes)
--          EXPECTED TO FAIL: sanitizePathSegment does not truncate.
--          This test documents a known limitation (FAT32 NAME_MAX = 255 bytes).
-- ===========================================================================

do
    -- 260 ASCII characters — each is 1 byte, total = 260 bytes.
    local long_title = string.rep("a", 260)
    local segment = SuwayomiPaths.sanitizePathSegment(long_title)
    assert_true(#segment <= 255,
        "long ASCII title: manga dir segment stays under Kindle 255-byte NAME_MAX "
        .. "[EXPECTED FAIL — sanitizePathSegment has no truncation]")
end

-- ===========================================================================
-- Test 12: Kindle constraint — Unicode title that is short in characters
--          but long in UTF-8 bytes
--          EXPECTED TO FAIL: sanitizePathSegment does not truncate by bytes.
-- ===========================================================================

do
    -- Each Japanese character is 3 bytes in UTF-8.
    -- 90 characters × 3 bytes = 270 bytes > 255.
    local long_unicode = string.rep("\xe4\xb8\x80", 90)  -- 90 × '一' (U+4E00)
    assert_eq(#long_unicode, 270,
        "unicode byte length: 90 × 3-byte char = 270 bytes (precondition)")
    local segment = SuwayomiPaths.sanitizePathSegment(long_unicode)
    assert_true(#segment <= 255,
        "long Unicode title: segment byte length stays under 255 "
        .. "[EXPECTED FAIL — sanitizePathSegment does not truncate by byte count]")
end

-- ---------------------------------------------------------------------------
-- Restore ffi/util state
-- ---------------------------------------------------------------------------

package.preload["ffi/util"] = old_ffi_util_preload
package.loaded["ffi/util"]  = old_ffi_util_loaded

if _standalone then
    print("\nChapter Path: see above for individual results")
end
