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

    -- Build a clean chapter number string (no ugly zero-padding)
    local chapter_num = tonumber(chapter.chapter_number)
    local ch_num_str
    if chapter_num then
        if chapter_num == math.floor(chapter_num) then
            ch_num_str = tostring(math.floor(chapter_num))  -- "1", "42", "100"
        else
            ch_num_str = string.format("%.1f", chapter_num)  -- "1.5", "10.5"
        end
    end

    -- Chapter title only — manga name lives in `series` so KOReader treats the
    -- folder as one book and each CBZ as a chapter of that book.
    -- Examples: "Ch. 1 - Romance Dawn", "Ch. 1.5 - Special", "Prologue"
    local chapter_title
    local ch_name = tostring(chapter.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if ch_num_str then
        if ch_name ~= "" then
            chapter_title = string.format("Ch. %s - %s", ch_num_str, ch_name)
        else
            chapter_title = string.format("Ch. %s", ch_num_str)
        end
    elseif ch_name ~= "" then
        chapter_title = ch_name
    else
        chapter_title = tostring(chapter.id or "Unknown Chapter")
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

    -- doc_props: series = manga (the "book"), title = chapter, series_index = order
    local doc_props = {
        title        = chapter_title,          -- "Ch. 1 - Romance Dawn"
        series       = manga.title or "",      -- "One Piece" (KOReader series / book name)
        series_index = chapter_num or 0,       -- 1
        authors      = authors_str,
        description  = manga.description,
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

-- Upsert one chapter into .manga_index.lua so the manga folder stays a navigable
-- "book with chapters" after every download without rebuilding from scratch.
function MangaMetadata.upsertMangaIndexChapter(manga_dir, manga, chapter, path)
    if not manga_dir or manga_dir == "" then
        return false
    end
    manga = type(manga) == "table" and manga or {}
    chapter = type(chapter) == "table" and chapter or {}

    local chapters = {}
    local index_path = manga_dir .. "/.manga_index.lua"
    local existing = io.open(index_path, "r")
    if existing then
        local content = existing:read("*a") or ""
        existing:close()
        local loader = loadstring(content)
        if loader then
            setfenv(loader, {})
            local ok, data = pcall(loader)
            if ok and type(data) == "table" and type(data.chapters) == "table" then
                for _, entry in ipairs(data.chapters) do
                    if type(entry) == "table" then
                        chapters[#chapters + 1] = {
                            chapter = {
                                id = entry.id,
                                name = entry.name,
                                chapter_number = entry.number,
                                source_order = entry.source_order or entry.number,
                            },
                            path = entry.path,
                        }
                    end
                end
            end
        end
    end

    local chapter_id = tostring(chapter.id or "")
    local replaced = false
    for i, entry in ipairs(chapters) do
        local existing_id = entry.chapter and tostring(entry.chapter.id or "") or ""
        if chapter_id ~= "" and existing_id == chapter_id then
            chapters[i] = { chapter = chapter, path = path }
            replaced = true
            break
        end
    end
    if not replaced then
        chapters[#chapters + 1] = { chapter = chapter, path = path }
    end

    return MangaMetadata.writeMangaIndex(manga_dir, manga, chapters)
end

-- Writes a .cover.jpg into the manga folder by copying from the thumbnail cache.
-- Skipped when the file already exists to avoid redundant I/O on every download.
--
-- manga_dir   : directory containing all chapter CBZs for this manga
-- manga       : manga table {id, title, thumbnail_url, ...}
-- credentials : Suwayomi auth credentials (passed through to thumbnail_cache)
function MangaMetadata.writeMangaCover(manga_dir, manga, credentials)
    if not manga_dir or manga_dir == "" then return false end
    manga = type(manga) == "table" and manga or {}
    local cover_dest = manga_dir .. "/.cover.jpg"

    -- Check if cover already exists
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if ok_lfs and lfs and lfs.attributes(cover_dest, "mode") == "file" then
        return true  -- already have a cover
    end

    -- Find cached thumbnail
    local thumb_url = manga.thumbnail_url
    if not thumb_url or thumb_url == "" then return false end

    local ok_tc, tc = pcall(require, "suwayomi/ui/thumbnail_cache")
    if not ok_tc or not tc then return false end

    local variants = {
        { variant = "manga_cover", width = 64, height = 96 },
        { variant = "poster", width = 240, height = 360 },
        { variant = "thumbnail" },
    }

    local src_path
    for _, opts in ipairs(variants) do
        local p = tc.find(credentials, thumb_url, opts)
        if p then src_path = p; break end
    end
    if not src_path then return false end

    -- Copy raw image bytes to cover destination
    local src = io.open(src_path, "rb")
    if not src then return false end
    local data = src:read("*a")
    src:close()
    if not data or #data == 0 then return false end

    local dst = io.open(cover_dest, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return true
end

return MangaMetadata
