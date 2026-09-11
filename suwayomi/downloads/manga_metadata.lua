-- Boundary: manga metadata sidecar generator.
--
-- Responsibility: write KOReader-compatible .sdr metadata files for downloaded
-- manga chapters so they appear correctly in KOReader's library with proper
-- title, series, and author metadata, and so the mangasync plugin can look up
-- the Suwayomi chapter ID without needing a separate index.
-- Owned state: none.
-- Dependencies: suwayomi/fs (KOReader lfs wrapper) for directory creation.
-- External data: manga/chapter tables are treated as potentially-nil and
-- sanitized before any filesystem write.

local MangaMetadata = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function ensureDirectory(path)
    if not path or path == "" then
        return false
    end
    local ok, lfs = pcall(require, "suwayomi/fs")
    if not ok or not lfs then
        return false
    end
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    local parent = tostring(path):match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and lfs.attributes(parent, "mode") ~= "directory" then
        ensureDirectory(parent)
    end
    return lfs.mkdir(path) or lfs.attributes(path, "mode") == "directory"
end

local function serializeValue(v)
    if type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "number" then
        return tostring(v)
    elseif v == nil then
        return "nil"
    else
        return tostring(v)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Writes a KOReader doc_props metadata file for a downloaded chapter CBZ.
-- This makes the chapter appear in KOReader with the manga title as series and
-- a formatted chapter title, and embeds the Suwayomi IDs so the mangasync
-- plugin can look up the chapter without a separate index file.
--
-- path    : full filesystem path to the CBZ file
-- manga   : manga table {id, title, author, artist, description, ...}
-- chapter : chapter table {id, name, chapter_number, source_order, ...}
--
-- Returns true on success, false on any failure (errors are suppressed).
function MangaMetadata.writeChapterMetadata(path, manga, chapter)
    if not path or path == "" then
        return false
    end
    manga = type(manga) == "table" and manga or {}
    chapter = type(chapter) == "table" and chapter or {}

    -- The .sdr sidecar directory lives alongside the CBZ:
    --   /Books/Source/MyManga/Ch001.cbz  →
    --   /Books/Source/MyManga/Ch001.cbz.sdr/metadata.cbz.lua
    local sdr_dir = path .. ".sdr"
    local metadata_path = sdr_dir .. "/metadata.cbz.lua"

    if not ensureDirectory(sdr_dir) then
        return false
    end

    -- Build a human-readable chapter title: "Ch. 001.0 - Chapter Name"
    local chapter_num = tonumber(chapter.chapter_number)
    local chapter_title
    if chapter_num then
        chapter_title = string.format("Ch. %05.1f - %s", chapter_num, chapter.name or "")
    else
        chapter_title = chapter.name or tostring(chapter.id or "Unknown Chapter")
    end

    -- Combine author and artist, deduplicating when they are the same person.
    local authors = {}
    local author = tostring(chapter.author or manga.author or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local artist = tostring(chapter.artist or manga.artist or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if author ~= "" then
        authors[#authors + 1] = author
    end
    if artist ~= "" and artist ~= author then
        authors[#authors + 1] = artist
    end
    local authors_str = #authors > 0 and table.concat(authors, ", ") or nil

    -- doc_props sub-table: consumed by KOReader's metadata system.
    local doc_props = {
        title = chapter_title,
        series = manga.title or "",
        series_index = chapter_num or 0,
        authors = authors_str,
        description = manga.description,
    }

    -- Serialize the full metadata table, including extended fields that the
    -- mangasync plugin reads to resolve the Suwayomi chapter_id.
    local lines = {
        "return {",
        '  ["doc_props"] = {',
    }
    for k, v in pairs(doc_props) do
        if v ~= nil then
            lines[#lines + 1] = string.format('    ["%s"] = %s,', k, serializeValue(v))
        end
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = string.format(
        '  ["suwayomi_chapter_id"] = %s,',
        serializeValue(tostring(chapter.id or ""))
    )
    lines[#lines + 1] = string.format(
        '  ["suwayomi_manga_id"] = %s,',
        serializeValue(tostring(manga.id or ""))
    )
    lines[#lines + 1] = "}"

    local f = io.open(metadata_path, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:write("\n")
        f:close()
        return true
    end
    return false
end

-- Writes a manga-level index file listing all downloaded chapters.
-- This is useful for building a "book with chapters" view, and can be called
-- incrementally — pass the full chapter list each time to overwrite cleanly.
--
-- manga_dir : directory containing all chapter CBZs for this manga
-- manga     : manga table {id, title, ...}
-- chapters  : array of { chapter = {id, name, chapter_number, source_order, ...},
--                        path    = "/full/path/to/chapter.cbz" }
function MangaMetadata.writeMangaIndex(manga_dir, manga, chapters)
    if not manga_dir or manga_dir == "" then
        return false
    end
    manga = type(manga) == "table" and manga or {}
    chapters = type(chapters) == "table" and chapters or {}

    -- Sort by source_order first, then by chapter_number as fallback.
    table.sort(chapters, function(a, b)
        local ca = type(a) == "table" and type(a.chapter) == "table" and a.chapter or {}
        local cb = type(b) == "table" and type(b.chapter) == "table" and b.chapter or {}
        local na = tonumber(ca.source_order) or tonumber(ca.chapter_number) or 0
        local nb = tonumber(cb.source_order) or tonumber(cb.chapter_number) or 0
        return na < nb
    end)

    local index_path = manga_dir .. "/.manga_index.lua"
    local lines = {
        "return {",
        string.format('  title = %q,', tostring(manga.title or "")),
        string.format('  manga_id = %q,', tostring(manga.id or "")),
        "  chapters = {",
    }
    for _, entry in ipairs(chapters) do
        local ch = type(entry) == "table" and type(entry.chapter) == "table" and entry.chapter or {}
        lines[#lines + 1] = string.format(
            '    { id = %q, name = %q, number = %s, path = %q },',
            tostring(ch.id or ""),
            tostring(ch.name or ""),
            tostring(ch.chapter_number or 0),
            tostring(entry.path or "")
        )
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"

    local f = io.open(index_path, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:write("\n")
        f:close()
        return true
    end
    return false
end

return MangaMetadata
