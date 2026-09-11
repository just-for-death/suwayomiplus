-- Boundary: source-scoped download path layout.
--
-- Responsibility: sanitize path segments and build manga/chapter paths using
-- the supported <download>/<source>/<manga>/<chapter>.cbz layout.
-- Owned state: none.
-- Dependencies: KOReader ffi/util path join helper.
-- External data: source, manga, and chapter labels are sanitized before becoming
-- filesystem path segments.

local FFIUtil = require("ffi/util")

local SuwayomiPaths = {}

local function truncateToBytesUTF8(s, max_bytes)
    if #s <= max_bytes then return s end
    -- Walk bytes, stopping at last valid UTF-8 boundary <= max_bytes
    local byte_count = 0
    local last_valid = 0
    local i = 1
    while i <= #s do
        local b = string.byte(s, i)
        local char_len
        if b < 0x80 then char_len = 1
        elseif b < 0xE0 then char_len = 2
        elseif b < 0xF0 then char_len = 3
        else char_len = 4 end
        if byte_count + char_len > max_bytes then break end
        byte_count = byte_count + char_len
        last_valid = byte_count
        i = i + char_len
    end
    return s:sub(1, last_valid)
end

local function normalizeDownloadDirectory(download_directory)
    if type(download_directory) ~= "string" or download_directory == "" then
        return nil
    end
    -- Prefer the real on-disk casing (FAT can store Manga vs manga inconsistently).
    local ok, real = pcall(function()
        return FFIUtil.realpath(download_directory)
    end)
    if ok and type(real) == "string" and real ~= "" then
        real = real:gsub("/+$", "")
        -- Canonical spelling for new indexes/settings: Books/Manga (capital M).
        local preferred = real:gsub("(/Books/)[Mm]anga$", "%1Manga")
        if preferred ~= real then
            -- Two-step rename so FAT actually flips the stored name.
            local tmp = preferred .. ".__case__"
            local renamed = os.rename(real, tmp) and os.rename(tmp, preferred)
            if renamed then
                return preferred
            end
            -- Rename failed (busy/permissions): keep preferred spelling in settings/
            -- indexes; FAT still resolves either casing to the same directory.
            return preferred
        end
        return real
    end
    return download_directory:gsub("/+$", ""):gsub("(/Books/)[Mm]anga$", "%1Manga")
end

--- Canonicalize a path for indexes/sidecars so we never mix Manga/manga casing.
function SuwayomiPaths.canonicalizePath(path)
    if type(path) ~= "string" or path == "" then
        return path
    end
    local ok, real = pcall(function()
        return FFIUtil.realpath(path)
    end)
    if ok and type(real) == "string" and real ~= "" then
        return real:gsub("(/Books/)[Mm]anga(/)", "%1Manga%2"):gsub("(/Books/)[Mm]anga$", "%1Manga")
    end
    return path:gsub("(/Books/)[Mm]anga(/)", "%1Manga%2"):gsub("(/Books/)[Mm]anga$", "%1Manga")
end

local function present(value)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    return value
end

local function appendUnique(list, seen, value)
    if value and value ~= "" and not seen[value] then
        seen[value] = true
        table.insert(list, value)
    end
end

function SuwayomiPaths.sanitizePathSegment(name)
    local sanitized = tostring(name or "")
        :gsub("%c+", " ")
        :gsub("[\\/:*?\"<>|]", "_")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if sanitized == "" or sanitized == "." or sanitized == ".." then
        return "untitled"
    end
    return truncateToBytesUTF8(sanitized, 200)
end

function SuwayomiPaths.getSourceLabel(manga)
    local source = manga and manga.source or {}
    local display_name = present(source.displayName) or present(source.display_name)
    if display_name then
        return display_name
    end

    local name = present(source.name) or present(source.raw_name)
    if name then
        local lang = present(source.lang)
        if lang and lang ~= "localsourcelang" then
            local lang_suffix = "%(" .. string.upper(lang) .. "%)$"
            if name:match(lang_suffix) then
                return name
            end
            return name .. " (" .. string.upper(lang) .. ")"
        end
        return name
    end

    return present(source.id) or "Unknown source"
end

function SuwayomiPaths.getMangaDirectory(download_directory, manga)
    download_directory = normalizeDownloadDirectory(download_directory)
    if not download_directory then
        return nil
    end
    local source_dir = FFIUtil.joinPath(download_directory, SuwayomiPaths.sanitizePathSegment(SuwayomiPaths.getSourceLabel(manga)))
    local manga_dir = FFIUtil.joinPath(source_dir, SuwayomiPaths.sanitizePathSegment(manga and manga.title))
    -- realpath only works once the directory exists; callers create it first.
    return manga_dir
end

function SuwayomiPaths.getChapterFilename(chapter)
    return SuwayomiPaths.getChapterFilenames(chapter)[1]
end

local function formatChapterSortPrefix(chapter)
    local num = chapter and tonumber(chapter.chapter_number)
    if num then
        if num == math.floor(num) then
            return string.format("Ch. %03d", math.floor(num))
        end
        return string.format("Ch. %05.1f", num)
    end
    local order = chapter and tonumber(chapter.source_order)
    if order then
        return string.format("Ch. %03d", math.floor(order))
    end
    return nil
end

function SuwayomiPaths.getChapterFilenames(chapter)
    local name = SuwayomiPaths.sanitizePathSegment(chapter and chapter.name)
    local filenames = {}
    local seen = {}
    local plain = name .. ".cbz"
    local id = chapter and present(chapter.id)
    local source_order = chapter and present(chapter.source_order)
    local chapter_number = chapter and present(chapter.chapter_number)
    local sort_prefix = formatChapterSortPrefix(chapter)

    local function addStable(label, value, base_name)
        if value then
            appendUnique(
                filenames,
                seen,
                (base_name or name) .. " [" .. label .. "-" .. SuwayomiPaths.sanitizePathSegment(value) .. "].cbz"
            )
        end
    end

    -- Book-like primary name: "Ch. 001 - Romance Dawn [id-123].cbz"
    -- Sorts naturally in the manga folder and stays unique via Suwayomi id.
    local book_base = sort_prefix
    if sort_prefix and name ~= "" and name ~= "untitled" then
        book_base = sort_prefix .. " - " .. name
    end
    if book_base then
        if id then
            addStable("id", id, book_base)
        elseif source_order then
            addStable("order", source_order, book_base)
        elseif chapter_number then
            addStable("chapter", chapter_number, book_base)
        else
            appendUnique(filenames, seen, book_base .. ".cbz")
        end
    end

    -- Older local names kept as lookup candidates for already-downloaded files.
    if id then
        addStable("id", id, name)
    elseif source_order then
        addStable("order", source_order, name)
    elseif chapter_number then
        addStable("chapter", chapter_number, name)
    end

    appendUnique(filenames, seen, plain)

    if id then
        addStable("order", source_order, name)
        addStable("chapter", chapter_number, name)
    elseif source_order then
        addStable("chapter", chapter_number, name)
    end

    return filenames
end

function SuwayomiPaths.getChapterPath(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    if not manga_dir then
        return nil
    end
    return FFIUtil.joinPath(
        manga_dir,
        SuwayomiPaths.getChapterFilename(chapter)
    )
end

function SuwayomiPaths.getChapterPathCandidates(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    if not manga_dir then
        return {}
    end

    local candidates = {}
    for _, filename in ipairs(SuwayomiPaths.getChapterFilenames(chapter)) do
        table.insert(candidates, FFIUtil.joinPath(manga_dir, filename))
    end
    return candidates
end

function SuwayomiPaths.getTargetPath(download_directory, manga, chapter)
    local manga_dir = SuwayomiPaths.getMangaDirectory(download_directory, manga)
    if not manga_dir then
        return nil, nil
    end
    manga_dir = SuwayomiPaths.canonicalizePath(manga_dir) or manga_dir
    local chapter_path = FFIUtil.joinPath(
        manga_dir,
        SuwayomiPaths.getChapterFilename(chapter)
    )
    return manga_dir, chapter_path
end

return SuwayomiPaths
