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
    elseif type(v) == "boolean" then
        return v and "true" or "false"
    elseif v == nil then
        return "nil"
    elseif type(v) == "table" then
        local parts = { "{" }
        for k, child in pairs(v) do
            local key
            if type(k) == "string" then
                key = string.format("[%q]", k)
            elseif type(k) == "number" then
                key = string.format("[%s]", tostring(k))
            else
                key = nil
            end
            if key then
                parts[#parts + 1] = key .. "=" .. serializeValue(child) .. ","
            end
        end
        parts[#parts + 1] = "}"
        return table.concat(parts)
    else
        return "nil"
    end
end

local function loadLuaTable(path)
    if not path or path == "" then
        return {}
    end
    local handle = io.open(path, "r")
    if not handle then
        return {}
    end
    local content = handle:read("*a") or ""
    handle:close()
    if content == "" then
        return {}
    end
    local loader = loadstring(content)
    if not loader then
        return {}
    end
    setfenv(loader, {})
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

local function saveLuaTable(path, data)
    if not path or path == "" or type(data) ~= "table" then
        return false
    end
    local ok_dump, dump = pcall(require, "dump")
    local handle = io.open(path, "w")
    if not handle then
        return false
    end
    handle:write("-- ", path, "\nreturn ")
    if ok_dump and dump then
        handle:write(dump(data, nil, true))
    else
        -- Nested-table fallback when dump.lua is unavailable (unit tests / odd hosts).
        handle:write(serializeValue(data))
    end
    handle:write("\n")
    handle:close()
    return true
end

local function buildChapterTitle(manga, chapter)
    manga = type(manga) == "table" and manga or {}
    chapter = type(chapter) == "table" and chapter or {}

    local chapter_num = tonumber(chapter.chapter_number)
    local ch_num_str
    if chapter_num then
        if chapter_num == math.floor(chapter_num) then
            ch_num_str = tostring(math.floor(chapter_num))
        else
            ch_num_str = string.format("%.1f", chapter_num)
        end
    end

    local ch_name = tostring(chapter.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if ch_num_str then
        if ch_name ~= "" then
            return string.format("Ch. %s - %s", ch_num_str, ch_name), chapter_num
        end
        return string.format("Ch. %s", ch_num_str), chapter_num
    end
    if ch_name ~= "" then
        return ch_name, chapter_num
    end
    return tostring(chapter.id or "Unknown Chapter"), chapter_num
end

local function buildAuthorsString(manga, chapter)
    manga = type(manga) == "table" and manga or {}
    chapter = type(chapter) == "table" and chapter or {}
    local authors = {}
    local author = tostring(chapter.author or manga.author or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local artist = tostring(chapter.artist or manga.artist or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if author ~= "" then
        authors[#authors + 1] = author
    end
    if artist ~= "" and artist ~= author then
        authors[#authors + 1] = artist
    end
    if #authors == 0 then
        return nil
    end
    return table.concat(authors, ", ")
end

-- Parse "Ch. 008 - Chapter 8 [id-32200].cbz" style filenames from Suwayomi+.
local function parseChapterFilename(filename)
    filename = tostring(filename or "")
    local num, name, id = filename:match("^Ch%. ([%d%.]+) %- (.+) %[id%-(%d+)%]%.cbz$")
    if id then
        return {
            id = id,
            name = name,
            chapter_number = tonumber(num),
            source_order = tonumber(num),
        }
    end
    id = filename:match("%[id%-(%d+)%]%.cbz$")
    if id then
        return {
            id = id,
            name = filename:gsub("%.cbz$", ""),
            chapter_number = tonumber(filename:match("Ch%. ([%d%.]+)") or ""),
            source_order = tonumber(filename:match("Ch%. ([%d%.]+)") or ""),
        }
    end
    return nil
end

local function getSidecarDir(doc_path)
    -- Match KOReader DocSettings: strip the last suffix, then append ".sdr".
    -- e.g. "Ch. 001.cbz" → "Ch. 001.sdr" (NOT "Ch. 001.cbz.sdr").
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.getSidecarDir then
        local dir = DocSettings:getSidecarDir(doc_path)
        if dir and dir ~= "" then
            return dir
        end
    end
    local base = tostring(doc_path or ""):match("(.*)%.") or tostring(doc_path or "")
    return base .. ".sdr"
end

local function getMetadataPath(doc_path)
    local sdr_dir = getSidecarDir(doc_path)
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.getSidecarFilename then
        return sdr_dir .. "/" .. DocSettings.getSidecarFilename(doc_path)
    end
    local suffix = tostring(doc_path or ""):match(".*%.(.+)$") or "cbz"
    return sdr_dir .. "/metadata." .. suffix .. ".lua"
end

local function migrateLegacyCbzSidecar(doc_path)
    -- Older Suwayomi+ builds wrote "file.cbz.sdr"; KOReader reads "file.sdr".
    local legacy = tostring(doc_path) .. ".sdr"
    local preferred = getSidecarDir(doc_path)
    if legacy == preferred then
        return
    end
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if not ok_lfs or not lfs then
        return
    end
    if lfs.attributes(legacy, "mode") ~= "directory" then
        return
    end
    if lfs.attributes(preferred, "mode") ~= "directory" then
        -- Prefer renaming the whole legacy sidecar into the KOReader location.
        if os.rename(legacy, preferred) then
            return
        end
    end
    -- Both exist: merge metadata keys from legacy into preferred, then drop legacy.
    local legacy_meta = legacy .. "/metadata.cbz.lua"
    local preferred_meta = getMetadataPath(doc_path)
    local legacy_data = loadLuaTable(legacy_meta)
    local preferred_data = loadLuaTable(preferred_meta)
    if next(legacy_data) ~= nil then
        for k, v in pairs(legacy_data) do
            if preferred_data[k] == nil then
                preferred_data[k] = v
            elseif k == "doc_props" and type(v) == "table" and type(preferred_data[k]) == "table" then
                for pk, pv in pairs(v) do
                    if preferred_data[k][pk] == nil or preferred_data[k][pk] == "" or preferred_data[k][pk] == "N/A" then
                        preferred_data[k][pk] = pv
                    end
                end
            elseif (k == "suwayomi_chapter_id" or k == "suwayomi_manga_id") and (preferred_data[k] == nil or preferred_data[k] == "") then
                preferred_data[k] = v
            end
        end
        ensureDirectory(preferred)
        saveLuaTable(preferred_meta, preferred_data)
    end
    -- Best-effort remove legacy sidecar tree.
    if type(lfs.dir) == "function" then
        for name in lfs.dir(legacy) do
            if name ~= "." and name ~= ".." then
                os.remove(legacy .. "/" .. name)
            end
        end
    end
    if type(lfs.rmdir) == "function" then
        lfs.rmdir(legacy)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Writes a KOReader doc_props metadata file for a downloaded chapter CBZ.
-- Merges into any existing sidecar so reader progress / annotations are kept.
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

    migrateLegacyCbzSidecar(path)

    local sdr_dir = getSidecarDir(path)
    local metadata_path = getMetadataPath(path)

    if not ensureDirectory(sdr_dir) then
        return false
    end

    local chapter_title, chapter_num = buildChapterTitle(manga, chapter)
    local authors_str = buildAuthorsString(manga, chapter)

    local existing = loadLuaTable(metadata_path)
    local doc_props = type(existing.doc_props) == "table" and existing.doc_props or {}
    doc_props.title = chapter_title
    doc_props.series = manga.title or doc_props.series or ""
    doc_props.series_index = chapter_num or doc_props.series_index or 0
    if authors_str then
        doc_props.authors = authors_str
    end
    if manga.description and tostring(manga.description) ~= "" then
        doc_props.description = manga.description
    end
    if doc_props.series == nil or doc_props.series == "" or doc_props.series == "N/A" then
        doc_props.series = manga.title or ""
    end

    existing.doc_props = doc_props
    existing.suwayomi_chapter_id = tostring(chapter.id or existing.suwayomi_chapter_id or "")
    existing.suwayomi_manga_id = tostring(manga.id or existing.suwayomi_manga_id or "")
    local ok_paths, SuwayomiPaths = pcall(require, "suwayomi/paths")
    if ok_paths and SuwayomiPaths and SuwayomiPaths.canonicalizePath then
        path = SuwayomiPaths.canonicalizePath(path) or path
    end
    if existing.doc_path == nil or existing.doc_path == "" or existing.doc_path ~= path then
        existing.doc_path = path
    end

    -- Pre-seed manga reading defaults: full page fit (no webtoon-like vertical scroll splits)
    -- and right-to-left reading order.
    if existing.zoom_mode == nil then
        existing.zoom_mode = "page"
    end
    if existing.normal_zoom_mode == nil then
        existing.normal_zoom_mode = "page"
    end
    if existing.inverse_reading_order == nil then
        existing.inverse_reading_order = true
    end
    if existing.kopt_page_scroll == nil then
        existing.kopt_page_scroll = 0
    end
    if existing.flipping_scroll_mode == nil then
        existing.flipping_scroll_mode = false
    end

    return saveLuaTable(metadata_path, existing)
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

    table.sort(chapters, function(a, b)
        local ca = type(a) == "table" and type(a.chapter) == "table" and a.chapter or {}
        local cb = type(b) == "table" and type(b.chapter) == "table" and b.chapter or {}
        local na = tonumber(ca.source_order) or tonumber(ca.chapter_number) or 0
        local nb = tonumber(cb.source_order) or tonumber(cb.chapter_number) or 0
        return na < nb
    end)

    local index_path = manga_dir .. "/.manga_index.lua"
    local ok_paths, SuwayomiPaths = pcall(require, "suwayomi/paths")
    if ok_paths and SuwayomiPaths and SuwayomiPaths.canonicalizePath then
        manga_dir = SuwayomiPaths.canonicalizePath(manga_dir) or manga_dir
    end
    local lines = {
        "return {",
        string.format('  title = %q,', tostring(manga.title or "")),
        string.format('  manga_id = %q,', tostring(manga.id or "")),
        "  chapters = {",
    }
    for _, entry in ipairs(chapters) do
        local ch = type(entry) == "table" and type(entry.chapter) == "table" and entry.chapter or {}
        local entry_path = tostring(entry.path or "")
        if ok_paths and SuwayomiPaths and SuwayomiPaths.canonicalizePath and entry_path ~= "" then
            entry_path = SuwayomiPaths.canonicalizePath(entry_path) or entry_path
        end
        -- Prefer paths under the canonical manga_dir when the basename matches.
        local base = entry_path:match("([^/]+)$")
        if base and base ~= "" then
            entry_path = manga_dir .. "/" .. base
        end
        lines[#lines + 1] = string.format(
            '    { id = %q, name = %q, number = %s, source_order = %s, path = %q },',
            tostring(ch.id or ""),
            tostring(ch.name or ""),
            tostring(ch.chapter_number or 0),
            tostring(ch.source_order or ch.chapter_number or 0),
            entry_path
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

-- Rebuild .manga_index.lua from every CBZ currently on disk (plus sidecar IDs).
function MangaMetadata.rebuildMangaIndexFromDirectory(manga_dir, manga)
    if not manga_dir or manga_dir == "" then
        return false
    end
    manga = type(manga) == "table" and manga or {}
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if not ok_lfs or not lfs then
        return false
    end

    local chapters = {}
    for file in lfs.dir(manga_dir) do
        if type(file) == "string" and file:match("%.cbz$") and not file:match("%.part") then
            local path = manga_dir .. "/" .. file
            if lfs.attributes(path, "mode") == "file" then
                local parsed = parseChapterFilename(file) or {}
                local meta = loadLuaTable(getMetadataPath(path))
                local chapter = {
                    id = tostring(meta.suwayomi_chapter_id or parsed.id or ""),
                    name = parsed.name or (meta.doc_props and meta.doc_props.title) or file,
                    chapter_number = tonumber(parsed.chapter_number)
                        or tonumber(meta.doc_props and meta.doc_props.series_index)
                        or 0,
                    source_order = tonumber(parsed.source_order)
                        or tonumber(parsed.chapter_number)
                        or tonumber(meta.doc_props and meta.doc_props.series_index)
                        or 0,
                }
                if chapter.id ~= "" or chapter.chapter_number > 0 then
                    chapters[#chapters + 1] = { chapter = chapter, path = path }
                end
                if (not manga.id or manga.id == "") and meta.suwayomi_manga_id and meta.suwayomi_manga_id ~= "" then
                    manga.id = meta.suwayomi_manga_id
                end
                if (not manga.title or manga.title == "") and meta.doc_props and meta.doc_props.series then
                    manga.title = meta.doc_props.series
                end
            end
        end
    end

    return MangaMetadata.writeMangaIndex(manga_dir, manga, chapters)
end

-- Upsert one chapter, then rebuild the index from disk so early chapters are never dropped.
function MangaMetadata.upsertMangaIndexChapter(manga_dir, manga, chapter, path)
    if not manga_dir or manga_dir == "" then
        return false
    end
    -- Ensure this chapter's sidecar carries IDs before the directory scan.
    if path and path ~= "" then
        MangaMetadata.writeChapterMetadata(path, manga, chapter)
    end
    return MangaMetadata.rebuildMangaIndexFromDirectory(manga_dir, manga)
end

-- Repair metadata + index + cover cache for an entire manga folder.
function MangaMetadata.repairMangaDirectory(manga_dir, manga, credentials)
    if not manga_dir or manga_dir == "" then
        return false
    end
    manga = type(manga) == "table" and manga or {}
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if not ok_lfs or not lfs then
        return false
    end

    local index = loadLuaTable(manga_dir .. "/.manga_index.lua")
    if index.title and (not manga.title or manga.title == "") then
        manga.title = index.title
    end
    if index.manga_id and (not manga.id or manga.id == "") then
        manga.id = index.manga_id
    end

    for file in lfs.dir(manga_dir) do
        if type(file) == "string" and file:match("%.cbz$") and not file:match("%.part") then
            local path = manga_dir .. "/" .. file
            if lfs.attributes(path, "mode") == "file" then
                local parsed = parseChapterFilename(file) or {}
                local meta = loadLuaTable(getMetadataPath(path))
                local chapter = {
                    id = tostring(meta.suwayomi_chapter_id or parsed.id or ""),
                    name = parsed.name or "Chapter",
                    chapter_number = tonumber(parsed.chapter_number)
                        or tonumber(meta.doc_props and meta.doc_props.series_index)
                        or 0,
                    source_order = tonumber(parsed.source_order) or tonumber(parsed.chapter_number) or 0,
                    author = manga.author,
                    artist = manga.artist,
                }
                MangaMetadata.writeChapterMetadata(path, manga, chapter)
                MangaMetadata.clearBookInfoCache(path)
            end
        end
    end

    MangaMetadata.rebuildMangaIndexFromDirectory(manga_dir, manga)
    if credentials then
        MangaMetadata.writeMangaCover(manga_dir, manga, credentials)
    end
    MangaMetadata.ignoreVisibleCoverBookInfo(manga_dir)
    return true
end

-- Visible cover.jpg / folder.jpg are indexed as "books" by CoverBrowser; hide
-- their metadata so mosaic/list focus on chapter CBZs. MaxOutUI uses .cover.jpg.
local COVER_FILENAMES = { "cover.jpg", "folder.jpg", ".cover.jpg" }
local VISIBLE_COVER_FILENAMES = { "cover.jpg", "folder.jpg" }

local function readFileHeader(path, nbytes)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local data = handle:read(nbytes or 16)
    handle:close()
    return data
end

local function isValidJpegBytes(data)
    return type(data) == "string"
        and #data >= 3
        and data:byte(1) == 0xFF
        and data:byte(2) == 0xD8
        and data:byte(3) == 0xFF
end

local function isValidJpegFile(path)
    return isValidJpegBytes(readFileHeader(path, 3))
end

local function sniffImageKind(data, content_type)
    if type(data) ~= "string" or #data < 12 then
        return nil
    end
    if data:sub(1, 8) == "SWTHUMB1" then
        return "swthumb"
    end
    if isValidJpegBytes(data) then
        return "jpeg"
    end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "png"
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return "webp"
    end

    content_type = tostring(content_type or ""):lower()
    if content_type:find("jpeg", 1, true) or content_type:find("jpg", 1, true) then
        return "jpeg"
    end
    if content_type:find("png", 1, true) then
        return "png"
    end
    if content_type:find("webp", 1, true) then
        return "webp"
    end
    return nil
end

local function hasValidFolderCovers(manga_dir)
    for _, name in ipairs(COVER_FILENAMES) do
        if not isValidJpegFile(manga_dir .. "/" .. name) then
            return false
        end
    end
    return true
end

local function writeBytes(path, data)
    local handle = io.open(path, "wb")
    if not handle then
        return false
    end
    local ok = handle:write(data)
    handle:close()
    return ok and true or false
end

local function decodeImageToBlitbuffer(data, kind)
    -- Preferred path for WebP/PNG/JPEG on KOReader: RenderImage (uses libwebp).
    -- Pic.openWebPDocumentFromData is often missing or fails in download subprocesses.
    do
        local ok_ri, RenderImage = pcall(require, "ui/renderimage")
        if ok_ri and RenderImage and RenderImage.renderImageData then
            local ok_bb, bitmap = pcall(function()
                return RenderImage:renderImageData(data, #data, false)
            end)
            if ok_bb and bitmap then
                return bitmap, nil
            end
        end
    end

    local ok_pic, Pic = pcall(require, "ffi/pic")
    if not ok_pic or not Pic then
        return nil
    end

    local ok_doc, doc_or_err = pcall(function()
        if kind == "jpeg" and Pic.openJPGDocumentFromData then
            return Pic.openJPGDocumentFromData(data, #data)
        end
        if kind == "webp" and Pic.openWebPDocumentFromData then
            return Pic.openWebPDocumentFromData(data, #data)
        end
        if kind == "webp" or kind == "png" or kind == "jpeg" then
            -- File-based openDocument fallback (PicDocument provider).
            local ext = (kind == "jpeg") and ".jpg" or ("." .. tostring(kind))
            local tmp = os.tmpname() .. ext
            if not writeBytes(tmp, data) then
                return nil
            end
            local ok_open, doc = pcall(function()
                if Pic.openDocument then
                    return Pic.openDocument(tmp)
                end
                return nil
            end)
            os.remove(tmp)
            if not ok_open then
                return nil
            end
            return doc
        end
        if kind == "png" and Pic.openPNGDocument then
            local tmp = os.tmpname() .. ".png"
            if not writeBytes(tmp, data) then
                return nil
            end
            local ok_open, doc = pcall(function()
                return Pic.openPNGDocument(tmp)
            end)
            os.remove(tmp)
            if not ok_open then
                return nil
            end
            return doc
        end
        return nil
    end)
    if not ok_doc or not doc_or_err then
        return nil
    end
    if doc_or_err.image_bb then
        return doc_or_err.image_bb, doc_or_err
    end
    -- Some Pic documents expose the bitmap via openPage(1).
    if doc_or_err.openPage then
        local ok_page, page = pcall(function()
            return doc_or_err:openPage(1)
        end)
        if ok_page and page and page.image_bb then
            return page.image_bb, doc_or_err
        end
    end
    return nil
end

local function blitbufferToJpegBytes(bb, doc)
    if not bb then
        return nil
    end
    local writeJPG = bb.writeJPG
    if not writeJPG and bb.copy then
        -- Some RenderImage bitmaps need a copied BB for writeJPG.
        local ok_copy, copied = pcall(function() return bb:copy() end)
        if ok_copy and copied and copied.writeJPG then
            bb = copied
            writeJPG = copied.writeJPG
        end
    end
    if not writeJPG then
        return nil
    end

    local tmp = os.tmpname() .. ".jpg"
    local ok_write = pcall(function()
        bb:writeJPG(tmp, 90)
    end)
    if doc and doc.close then
        pcall(function() doc:close() end)
    end
    -- Free RenderImage bitmap when we own it.
    if bb.free then
        pcall(function() bb:free() end)
    end
    if not ok_write then
        os.remove(tmp)
        return nil
    end

    local handle = io.open(tmp, "rb")
    if not handle then
        os.remove(tmp)
        return nil
    end
    local jpeg = handle:read("*a")
    handle:close()
    os.remove(tmp)
    if not isValidJpegBytes(jpeg) then
        return nil
    end
    return jpeg
end

-- Convert downloaded thumbnail bytes into real JPEG bytes for folder covers.
-- Suwayomi often serves WebP; the UI thumbnail cache uses SWTHUMB1 (not an image).
local function toJpegBytes(data, content_type)
    local kind = sniffImageKind(data, content_type)
    if not kind or kind == "swthumb" then
        return nil
    end
    if kind == "jpeg" then
        return data
    end

    local bb, doc = decodeImageToBlitbuffer(data, kind)
    return blitbufferToJpegBytes(bb, doc)
end

-- Prefer raw JPEG page bytes (no decoder). CBZ pages are usually already JPEG.
local function bytesToCoverJpeg(bytes)
    if type(bytes) ~= "string" or #bytes < 4 then
        return nil
    end
    if isValidJpegBytes(bytes) then
        return bytes
    end
    return toJpegBytes(bytes, nil)
end

local function listCbzImageEntriesViaUnzip(cbz_path)
    -- Kindle BusyBox unzip has no -Z1; parse `unzip -l` instead.
    local quoted = cbz_path:gsub('"', '\\"')
    local listing = io.popen('unzip -l "' .. quoted .. '" 2>/dev/null')
    if not listing then
        return {}
    end
    local entries = {}
    for line in listing:lines() do
        -- Typical: "   319089  00-00-1980 00:00   0001.jpg"
        local name = line:match("%d%d:%d%d%s+(.+)$")
        if type(name) == "string" then
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            if name:match("%.[Jj][Pp][Ee]?[Gg]$")
                or name:match("%.[Pp][Nn][Gg]$")
                or name:match("%.[Ww][Ee][Bb][Pp]$") then
                entries[#entries + 1] = name
            end
        end
    end
    listing:close()
    table.sort(entries)
    return entries
end

-- Last-resort cover: first image page inside the first chapter CBZ.
-- Used when the Suwayomi thumbnail is WebP and on-device WebP decode fails
-- (common in download subprocesses). Chapter pages are usually already JPEG.
local function jpegFromFirstChapterPage(manga_dir)
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if not ok_lfs or not lfs then
        return nil
    end
    local candidates = {}
    for file in lfs.dir(manga_dir) do
        if type(file) == "string" and file:match("%.cbz$") and not file:match("%.part") then
            candidates[#candidates + 1] = file
        end
    end
    table.sort(candidates)
    if #candidates == 0 then
        return nil
    end

    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    local cbz_path = manga_dir .. "/" .. candidates[1]
    if ok_arc and Archiver and Archiver.Reader then
        local ok_open, reader = pcall(function()
            return Archiver.Reader:new(cbz_path)
        end)
        if ok_open and reader then
            local names = {}
            pcall(function()
                for name in reader:iterate() do
                    if type(name) == "string" and name:match("%.[Jj][Pp][Ee]?[Gg]$") then
                        names[#names + 1] = name
                    elseif type(name) == "string" and name:match("%.[Pp][Nn][Gg]$") then
                        names[#names + 1] = name
                    elseif type(name) == "string" and name:match("%.[Ww][Ee][Bb][Pp]$") then
                        names[#names + 1] = name
                    end
                end
            end)
            table.sort(names)
            for _, name in ipairs(names) do
                local ok_ext, bytes = pcall(function()
                    return reader:extractToMemory(name)
                end)
                if ok_ext and type(bytes) == "string" and #bytes > 0 then
                    local jpeg = bytesToCoverJpeg(bytes)
                    if jpeg then
                        pcall(function() reader:close() end)
                        return jpeg
                    end
                end
            end
            pcall(function() reader:close() end)
        end
    end

    -- Fallback: BusyBox-compatible unzip -l / unzip -p.
    local entries = listCbzImageEntriesViaUnzip(cbz_path)
    local quoted_cbz = cbz_path:gsub('"', '\\"')
    for _, entry in ipairs(entries) do
        local pipe = io.popen('unzip -p "' .. quoted_cbz .. '" "' .. entry:gsub('"', '\\"') .. '" 2>/dev/null')
        if pipe then
            local bytes = pipe:read("*a")
            pipe:close()
            local jpeg = bytesToCoverJpeg(bytes)
            if jpeg then
                return jpeg
            end
        end
    end
    return nil
end

function MangaMetadata.writeCoverFiles(manga_dir, body, content_type)
    if not manga_dir or manga_dir == "" then
        return false
    end
    local jpeg = nil
    local kind = (body and body ~= "") and sniffImageKind(body, content_type) or nil
    -- Prefer a real server thumbnail whenever we can turn it into JPEG.
    -- Parent-process ensureCoversAfterFinish has RenderImage; only fall back
    -- to the first chapter page when decode fails (common in bare subprocesses).
    if kind == "jpeg" then
        jpeg = body
    elseif body and body ~= "" then
        jpeg = toJpegBytes(body, content_type)
    end
    if not jpeg then
        jpeg = jpegFromFirstChapterPage(manga_dir)
    end
    if not jpeg then
        return false
    end

    local wrote = false
    for _, name in ipairs(COVER_FILENAMES) do
        local path = manga_dir .. "/" .. name
        if writeBytes(path, jpeg) then
            wrote = true
            MangaMetadata.clearBookInfoCache(path)
        end
    end
    if wrote then
        MangaMetadata.ignoreVisibleCoverBookInfo(manga_dir)
    end
    return wrote
end

-- Clear a CoverBrowser bookinfo row so a permanent "unsupported" / stale cover
-- mark cannot stick after we finish (or rewrite) a file.
function MangaMetadata.clearBookInfoCache(filepath)
    if not filepath or filepath == "" then
        return false
    end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or not BookInfoManager or not BookInfoManager.deleteBookInfo then
        return false
    end
    local deleted = pcall(function()
        BookInfoManager:deleteBookInfo(filepath)
    end)
    return deleted and true or false
end

-- Remove accidental DocSettings sidecars CoverBrowser creates for cover.jpg /
-- folder.jpg (they show up as orphan *.sdr next to the manga folder).
local function removeVisibleCoverSidecars(manga_dir)
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if not ok_lfs or not lfs then
        return
    end
    for _, name in ipairs(VISIBLE_COVER_FILENAMES) do
        local cover_path = manga_dir .. "/" .. name
        local base = cover_path:match("^(.*)%.[^./]+$") or cover_path
        local sdr = base .. ".sdr"
        if lfs.attributes(sdr, "mode") == "directory" then
            for fname in lfs.dir(sdr) do
                if fname ~= "." and fname ~= ".." then
                    os.remove(sdr .. "/" .. fname)
                end
            end
            lfs.rmdir(sdr)
        end
        -- Legacy mistaken layout: cover.jpg.sdr
        local legacy = cover_path .. ".sdr"
        if lfs.attributes(legacy, "mode") == "directory" then
            for fname in lfs.dir(legacy) do
                if fname ~= "." and fname ~= ".." then
                    os.remove(legacy .. "/" .. fname)
                end
            end
            lfs.rmdir(legacy)
        end
    end
end

-- Mark cover.jpg / folder.jpg so CoverBrowser does not treat them as chapters.
function MangaMetadata.ignoreVisibleCoverBookInfo(manga_dir)
    if not manga_dir or manga_dir == "" then
        return false
    end
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then
        removeVisibleCoverSidecars(manga_dir)
        return false
    end
    local marked = false
    for _, name in ipairs(VISIBLE_COVER_FILENAMES) do
        local path = manga_dir .. "/" .. name
        if not ok_lfs or not lfs or lfs.attributes(path, "mode") == "file" then
            MangaMetadata.clearBookInfoCache(path)
            if BookInfoManager.setBookInfoProperties then
                local ok_set = pcall(function()
                    -- getBookInfo creates/refreshes the row; then mark as ignored noise.
                    if BookInfoManager.getBookInfo then
                        BookInfoManager:getBookInfo(path, true)
                    end
                    BookInfoManager:setBookInfoProperties(path, {
                        ignore_meta = "Y",
                    })
                end)
                if ok_set then
                    marked = true
                end
            end
        end
    end
    MangaMetadata.clearBookInfoCache(manga_dir .. "/.cover.jpg")
    -- Drop sidecar dirs CoverBrowser may have already created for the JPGs.
    removeVisibleCoverSidecars(manga_dir)
    return marked
end

-- Writes cover.jpg / folder.jpg / .cover.jpg as real JPEGs into the manga folder.
-- Downloads the server thumbnail (never copies SWTHUMB1 UI cache entries).
-- Rewrites when existing files are missing or not valid JPEGs (e.g. WebP mislabeled .jpg).
--
-- manga_dir   : directory containing all chapter CBZs for this manga
-- manga       : manga table {id, title, thumbnail_url, ...}
-- credentials : Suwayomi auth credentials
function MangaMetadata.writeMangaCover(manga_dir, manga, credentials)
    if not manga_dir or manga_dir == "" then
        return false
    end
    manga = type(manga) == "table" and manga or {}

    if hasValidFolderCovers(manga_dir) then
        MangaMetadata.ignoreVisibleCoverBookInfo(manga_dir)
        return true
    end

    local thumb_url = manga.thumbnailUrl
        or manga.thumbnail_url
        or (manga.manga and (manga.manga.thumbnailUrl or manga.manga.thumbnail_url))
    if not thumb_url or thumb_url == "" then
        local manga_id = manga.id or (manga.manga and manga.manga.id)
        if manga_id then
            thumb_url = "/api/v1/manga/" .. tostring(manga_id) .. "/thumbnail"
        end
    end

    local body, content_type
    if thumb_url and thumb_url ~= "" then
        local ok_api, SuwayomiAPI = pcall(require, "suwayomi/api")
        if ok_api and SuwayomiAPI and SuwayomiAPI.downloadBinary then
            local res = SuwayomiAPI.downloadBinary(credentials, thumb_url)
            if res and res.ok and res.body and #res.body > 0 then
                body = res.body
                content_type = res.content_type
            end
        end
    end

    -- writeCoverFiles decodes WebP/PNG via RenderImage and falls back to the
    -- first chapter page when the server thumbnail cannot be converted.
    return MangaMetadata.writeCoverFiles(manga_dir, body, content_type)
end

return MangaMetadata
