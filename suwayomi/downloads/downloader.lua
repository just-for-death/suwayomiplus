-- Boundary: one-chapter device-local downloader.
--
-- Responsibility: download pages or direct archives, validate page data, write
-- ordered CBZ files, clean partial files, and report progress.
-- Owned state: none.
-- Dependencies: filesystem loader, KOReader archiver, API facade, and path helpers.
-- External data: page URLs, archive bytes, filesystem paths, and API responses
-- are validated before final CBZ rename.

local lfs = require("suwayomi/fs")
local Archiver = require("ffi/archiver")
local SuwayomiAPI = require("suwayomi/api")
local ProgressFile = require("suwayomi/downloads/progress_file")
local SuwayomiPaths = require("suwayomi/paths")
local bit = rawget(_G, "bit") or require("bit")

local Downloader = {}
local DOWNLOAD_RETRY_DELAYS_SECONDS = { 0.5, 1 }

-- Write KOReader sidecar metadata + manga-folder book index after a successful
-- chapter download. Uses pcall throughout so metadata failure never aborts download.
local function tryWriteChapterMetadata(final_path, manga, chapter)
    if not final_path or final_path == "" or not manga or not chapter then
        return
    end
    local ok, MangaMetadata = pcall(require, "suwayomi/downloads/manga_metadata")
    if not (ok and MangaMetadata) then
        return
    end
    if MangaMetadata.writeChapterMetadata then
        pcall(function()
            MangaMetadata.writeChapterMetadata(final_path, manga, chapter)
        end)
    end
    local manga_dir = tostring(final_path):match("^(.*)/[^/]+$")
    if manga_dir and MangaMetadata.upsertMangaIndexChapter then
        pcall(function()
            MangaMetadata.upsertMangaIndexChapter(manga_dir, manga, chapter, final_path)
        end)
    end
end

-- Write real JPEG folder covers (cover.jpg / folder.jpg / .cover.jpg).
-- Rewrites broken WebP-as-.jpg or SWTHUMB1 cache copies when needed.
--
-- MUST run synchronously here. Downloads usually finish inside a subprocess that
-- calls os.exit() right after writeSidecarsForChapter; a UIManager:scheduleIn
-- callback never runs in that child, which left manga folders (e.g. Tower
-- Dungeon) with no covers. writeMangaCover short-circuits once valid JPEGs
-- exist, so only the first chapter of a series pays the thumbnail GET.
local function tryWriteMangaCover(manga_dir, manga, credentials)
    if not manga_dir or not manga then return end
    pcall(function()
        local ok_mm, MM = pcall(require, "suwayomi/downloads/manga_metadata")
        if ok_mm and MM and MM.writeMangaCover then
            MM.writeMangaCover(manga_dir, manga, credentials)
        end
    end)
end

-- Drop CoverBrowser bookinfo rows so a prior crash/"unsupported" mark cannot
-- permanently hide a chapter thumb, and so rewritten folder covers re-extract.
local function tryClearBookInfo(filepath)
    if not filepath or filepath == "" then
        return
    end
    pcall(function()
        local ok_mm, MM = pcall(require, "suwayomi/downloads/manga_metadata")
        if ok_mm and MM and MM.clearBookInfoCache then
            MM.clearBookInfoCache(filepath)
        end
    end)
end

-- Public so active_jobs (subprocess + inline finish) can write sidecars once.
-- Covers are intentionally NOT written here: the download child often cannot
-- decode Suwayomi WebP thumbs, and a chapter-page fallback would short-circuit
-- the parent ensureCoversAfterFinish pass (which has RenderImage).
function Downloader:writeSidecarsForChapter(final_path, manga, chapter, credentials)
    tryWriteChapterMetadata(final_path, manga, chapter)
    -- Allow CoverBrowser to extract a fresh thumb for this finished CBZ.
    tryClearBookInfo(final_path)
end

-- CRC-32 for store-method ZIP entries (Kindle FSP is unreliable with libarchive
-- streaming writes, so we prefer a simple STORED zip built with plain file IO).
local crc_table
local CRC_CHUNK_SIZE = 64 * 1024

local function ensureCrcTable()
    if crc_table then
        return
    end
    crc_table = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if c % 2 == 1 then
                c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
            else
                c = bit.rshift(c, 1)
            end
        end
        crc_table[i] = c
    end
end

local function crc32Update(crc, data)
    for i = 1, #data do
        local b = data:byte(i)
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, b), 0xFF)])
    end
    return crc
end

-- Stream CRC from an open file handle (64KB chunks) so large pages do not need
-- a second full in-memory copy just for the checksum.
local function crc32FromHandle(handle)
    ensureCrcTable()
    local crc = 0xFFFFFFFF
    while true do
        local chunk = handle:read(CRC_CHUNK_SIZE)
        if not chunk or chunk == "" then
            break
        end
        crc = crc32Update(crc, chunk)
    end
    -- LuaJIT bit ops are signed; keep CRC in unsigned 32-bit range for ZIP headers.
    return bit.band(bit.bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
end

local function u16(n)
    n = bit.band(n or 0, 0xFFFF)
    return string.char(bit.band(n, 0xFF), bit.rshift(n, 8))
end

local function u32(n)
    n = bit.band(n or 0, 0xFFFFFFFF)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 24), 0xFF)
    )
end

-- Build a STORED (no compression) zip from on-disk page files.
-- Avoids Archiver.Writer:addFileFromMemory "Write error" on Kindle FSP.
-- CRC and payload are streamed in chunks so packing does not hold two full
-- page buffers (CRC + write) at once.
local function writeStoredZipFromFiles(zip_path, files)
    local out = io.open(zip_path, "wb")
    if not out then
        return false, "Could not create chapter archive."
    end

    local entries = {}
    for _, file in ipairs(files) do
        local handle = io.open(file.path, "rb")
        if not handle then
            out:close()
            os.remove(zip_path)
            return false, "Could not read downloaded page file."
        end
        local size = handle:seek("end") or 0
        handle:seek("set")
        local crc = crc32FromHandle(handle)
        handle:seek("set")

        local offset = out:seek()
        local name = file.name
        -- Local file header (STORED)
        out:write("PK\003\004")
        out:write(u16(20))      -- version needed
        out:write(u16(0))       -- flags
        out:write(u16(0))       -- method store
        out:write(u16(0))       -- time
        out:write(u16(0))       -- date
        out:write(u32(crc))
        out:write(u32(size))
        out:write(u32(size))
        out:write(u16(#name))
        out:write(u16(0))       -- extra len
        out:write(name)
        while true do
            local chunk = handle:read(CRC_CHUNK_SIZE)
            if not chunk or chunk == "" then
                break
            end
            out:write(chunk)
        end
        handle:close()
        entries[#entries + 1] = {
            name = name,
            crc = crc,
            size = size,
            offset = offset,
        }
    end

    local cd_offset = out:seek()
    for _, entry in ipairs(entries) do
        out:write("PK\001\002")
        out:write(u16(20))      -- version made by
        out:write(u16(20))      -- version needed
        out:write(u16(0))
        out:write(u16(0))       -- store
        out:write(u16(0))
        out:write(u16(0))
        out:write(u32(entry.crc))
        out:write(u32(entry.size))
        out:write(u32(entry.size))
        out:write(u16(#entry.name))
        out:write(u16(0))
        out:write(u16(0))
        out:write(u16(0))
        out:write(u16(0))
        out:write(u32(0))
        out:write(u32(entry.offset))
        out:write(entry.name)
    end
    local cd_size = out:seek() - cd_offset
    out:write("PK\005\006")
    out:write(u16(0))
    out:write(u16(0))
    out:write(u16(#entries))
    out:write(u16(#entries))
    out:write(u32(cd_size))
    out:write(u32(cd_offset))
    out:write(u16(0))
    out:close()
    return true
end

local function removeDirectoryTree(path)
    if not path or path == "" or not lfs.attributes then
        return
    end
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                removeDirectoryTree(path .. "/" .. name)
            end
        end
        lfs.rmdir(path)
    elseif mode == "file" then
        os.remove(path)
    end
end

-- Large chapters routinely take minutes over a remote link; the per-request
-- default is sized for single pages.
local CHAPTER_ARCHIVE_TIMEOUT_SECONDS = 300

local function sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then
        socket.sleep(seconds)
    end
end

local function isTransientDownloadError(error_message)
    error_message = tostring(error_message or ""):lower()
    return error_message:match("timed out") ~= nil
        or error_message:match("timeout") ~= nil
        or error_message:match("could not reach") ~= nil
        or error_message:match("could not download chapter page") ~= nil
        or error_message:match("too many requests") ~= nil
        or error_message:match("rate limit") ~= nil
        or error_message:match("server error") ~= nil
        or error_message:match("bad gateway") ~= nil
        or error_message:match("service unavailable") ~= nil
        or error_message:match("gateway timeout") ~= nil
end

local function isRetryableResult(result)
    if type(result) == "table" and result.retryable ~= nil then
        return result.retryable == true
    end
    return isTransientDownloadError(result and result.error)
end

local function callWithTransientRetry(callback)
    local result
    for attempt = 1, #DOWNLOAD_RETRY_DELAYS_SECONDS + 1 do
        result = callback() or {}
        if result.ok == true then
            return result
        end
        if attempt > #DOWNLOAD_RETRY_DELAYS_SECONDS or not isRetryableResult(result) then
            return result
        end
        sleep(DOWNLOAD_RETRY_DELAYS_SECONDS[attempt])
    end
    return result
end

function Downloader:sanitizePathSegment(name)
    return SuwayomiPaths.sanitizePathSegment(name)
end

function Downloader:getTargetPath(download_directory, manga, chapter)
    return SuwayomiPaths.getTargetPath(download_directory, manga, chapter)
end

function Downloader:getChapterPathCandidates(download_directory, manga, chapter)
    if SuwayomiPaths.getChapterPathCandidates then
        return SuwayomiPaths.getChapterPathCandidates(download_directory, manga, chapter)
    end
    local _, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    return chapter_path and { chapter_path } or {}
end

function Downloader:findExistingPathInCandidates(candidates)
    for _, path in ipairs(candidates or {}) do
        if self:chapterExists(path) then
            return path
        end
    end
    return nil
end

function Downloader:findExistingChapterPath(download_directory, manga, chapter)
    return self:findExistingPathInCandidates(self:getChapterPathCandidates(download_directory, manga, chapter))
end

-- Keep incomplete downloads under a hidden folder so CoverBrowser / file
-- manager do not index `.part.pages` dirs or half-written archives (those
-- caused "too many interruptions" / "not readable" permanent cover failures).
local STAGING_DIR_NAME = ".suwayomi_tmp"

function Downloader:getStagingDirectory(manga_dir)
    return tostring(manga_dir or "") .. "/" .. STAGING_DIR_NAME
end

function Downloader:getPartialPath(chapter_path)
    local manga_dir, filename = tostring(chapter_path or ""):match("^(.*)/([^/]+)$")
    if not manga_dir or manga_dir == "" or not filename or filename == "" then
        return tostring(chapter_path or "") .. ".part"
    end
    return self:getStagingDirectory(manga_dir) .. "/" .. filename .. ".part"
end

function Downloader:getDirectPartialPath(chapter_path)
    local manga_dir, filename = tostring(chapter_path or ""):match("^(.*)/([^/]+)$")
    if not manga_dir or manga_dir == "" or not filename or filename == "" then
        return tostring(chapter_path or "") .. ".direct.part"
    end
    return self:getStagingDirectory(manga_dir) .. "/" .. filename .. ".direct.part"
end

-- Remove pre-1.3.6 staging that sat next to the final CBZ (visible to CoverBrowser).
function Downloader:cleanupLegacyPartials(chapter_path)
    chapter_path = tostring(chapter_path or "")
    if chapter_path == "" then
        return
    end
    self:cleanupPartialFile(chapter_path .. ".part")
    self:cleanupPartialFile(chapter_path .. ".direct.part")
    removeDirectoryTree(chapter_path .. ".part.pages")
    removeDirectoryTree(chapter_path .. ".direct.part.pages")
end

-- Remove all in-progress files for one chapter (hidden staging + legacy paths).
function Downloader:pruneEmptyStagingDirectory(manga_dir)
    local staging = self:getStagingDirectory(manga_dir)
    if not staging or staging == "" or staging == "/" .. STAGING_DIR_NAME then
        return
    end
    if not lfs.attributes or lfs.attributes(staging, "mode") ~= "directory" then
        return
    end
    for name in lfs.dir(staging) do
        if name ~= "." and name ~= ".." then
            return
        end
    end
    lfs.rmdir(staging)
end

function Downloader:cleanupChapterStaging(chapter_path)
    chapter_path = tostring(chapter_path or "")
    if chapter_path == "" then
        return false
    end
    self:cleanupLegacyPartials(chapter_path)
    local partial_path = self:getPartialPath(chapter_path)
    local direct_path = self:getDirectPartialPath(chapter_path)
    self:cleanupPartialFile(partial_path)
    self:cleanupPartialFile(direct_path)
    removeDirectoryTree(tostring(partial_path) .. ".pages")
    removeDirectoryTree(tostring(direct_path) .. ".pages")
    local manga_dir = chapter_path:match("^(.*)/[^/]+$")
    if manga_dir and manga_dir ~= "" then
        self:pruneEmptyStagingDirectory(manga_dir)
    end
    return true
end

function Downloader:chapterExists(chapter_path)
    return lfs.attributes(chapter_path, "mode") == "file"
end

function Downloader:ensureDirectory(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end

    local parent = tostring(path or ""):match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path and lfs.attributes(parent, "mode") ~= "directory" then
        local parent_ok, parent_error = self:ensureDirectory(parent)
        if not parent_ok then
            return false, parent_error
        end
    end

    if lfs.mkdir(path) then
        return true
    end

    return false, "Could not create manga folder."
end

function Downloader:ensureMangaCover(credentials, manga_dir, manga)
    local ok_mm, MM = pcall(require, "suwayomi/downloads/manga_metadata")
    if ok_mm and MM and MM.writeMangaCover then
        MM.writeMangaCover(manga_dir, manga, credentials)
    end
end

function Downloader:cleanupPartialFile(path)
    if path and path ~= "" then
        local removed = os.remove(path)
        if removed then
            return true
        end
        if not lfs.attributes then
            return true
        end
        if lfs.attributes(path, "mode") ~= "file" then
            return true
        end
        return false, "Could not remove partial chapter archive."
    end
    return true
end

function Downloader:failAndCleanup(message, chapter_path, writer)
    if writer then
        local closed, close_error = self:closeArchiveWriter(writer)
        if not closed and close_error and close_error ~= "" then
            message = tostring(message or "") .. " " .. tostring(close_error)
        end
    end
    local cleanup_ok, cleanup_error = self:cleanupPartialFile(chapter_path)
    local result = {
        ok = false,
        error = message,
    }
    if not cleanup_ok then
        result.cleanup_error = cleanup_error
    end
    return result
end

function Downloader:closeArchiveWriter(writer)
    if not writer then
        return true
    end

    local ok, closed, close_error = pcall(function()
        return writer:close()
    end)
    if not ok then
        return false, "Could not close chapter archive. " .. tostring(closed)
    end
    if closed == false or close_error ~= nil then
        return false, "Could not close chapter archive. " .. tostring(close_error or writer.err or "unknown error")
    end
    return true
end

function Downloader:isArchiveContentType(content_type)
    content_type = tostring(content_type or ""):lower()
    return content_type:match("comicbook") ~= nil
        or content_type:match("cbz") ~= nil
        or content_type:match("zip") ~= nil
end

function Downloader:isZipHeader(header_bytes)
    header_bytes = tostring(header_bytes or "")
    return header_bytes:sub(1, 4) == "PK\003\004"
        or header_bytes:sub(1, 4) == "PK\005\006"
        or header_bytes:sub(1, 4) == "PK\007\008"
end

local function readUInt16LE(bytes, index)
    local first = bytes:byte(index)
    local second = bytes:byte(index + 1)
    if not first or not second then
        return nil
    end
    return first + (second * 256)
end

local function readUInt32LE(bytes, index)
    local low = readUInt16LE(bytes, index)
    local high = readUInt16LE(bytes, index + 2)
    if not low or not high then
        return nil
    end
    return low + (high * 65536)
end

local function hasFlag(value, flag)
    return value and value % (flag * 2) >= flag
end

local function parseCentralDirectoryEntry(bytes, index, limit)
    if index + 45 > limit or bytes:sub(index, index + 3) ~= "PK\001\002" then
        return nil
    end

    local name_length = readUInt16LE(bytes, index + 28)
    local extra_length = readUInt16LE(bytes, index + 30)
    local comment_length = readUInt16LE(bytes, index + 32)
    local compressed_size = readUInt32LE(bytes, index + 20)
    local local_header_offset = readUInt32LE(bytes, index + 42)
    local flags = readUInt16LE(bytes, index + 8)
    if not name_length
        or name_length == 0
        or not extra_length
        or not comment_length
        or not compressed_size
        or not local_header_offset
        or not flags
    then
        return nil
    end

    local length = 46 + name_length + extra_length + comment_length
    if index + length - 1 > limit then
        return nil
    end

    return {
        length = length,
        name_length = name_length,
        compressed_size = compressed_size,
        local_header_offset = local_header_offset,
        flags = flags,
    }
end

local function readArchiveBytes(archive_result, archive_path, offset, length)
    local head_bytes = tostring(archive_result.head_bytes or archive_result.header_bytes or "")
    if offset >= 0 and offset + length <= #head_bytes then
        return head_bytes:sub(offset + 1, offset + length)
    end

    local tail_bytes = tostring(archive_result.tail_bytes or "")
    local tail_offset = (archive_result.bytes or 0) - #tail_bytes
    if offset >= tail_offset and offset + length <= tail_offset + #tail_bytes then
        local start_index = offset - tail_offset + 1
        return tail_bytes:sub(start_index, start_index + length - 1)
    end

    if not archive_path or archive_path == "" then
        return nil
    end
    local handle = io.open(archive_path, "rb")
    if not handle then
        return nil
    end
    local seek_ok = handle:seek("set", offset)
    local bytes
    if seek_ok then
        bytes = handle:read(length)
    end
    handle:close()
    if type(bytes) ~= "string" or #bytes ~= length then
        return nil
    end
    return bytes
end

local function parseLocalHeader(archive_result, archive_path, offset)
    local header = readArchiveBytes(archive_result, archive_path, offset, 30)
    if not header or header:sub(1, 4) ~= "PK\003\004" then
        return nil
    end

    local flags = readUInt16LE(header, 7)
    local compressed_size = readUInt32LE(header, 19)
    local name_length = readUInt16LE(header, 27)
    local extra_length = readUInt16LE(header, 29)
    if not flags or not compressed_size or not name_length or not extra_length or name_length == 0 then
        return nil
    end

    return {
        flags = flags,
        compressed_size = compressed_size,
        name_length = name_length,
        header_length = 30 + name_length + extra_length,
    }
end

local function isAllowedDescriptorGap(uses_data_descriptor, gap)
    if uses_data_descriptor then
        return gap == 12 or gap == 16
    end
    return gap == 0
end

function Downloader:isZipArchiveResult(archive_result, archive_path)
    if not archive_result or (archive_result.bytes or 0) < 22 then
        return false
    end
    local header_signature = tostring(archive_result.header_bytes or ""):sub(1, 4)
    if not self:isZipHeader(header_signature) then
        return false
    end

    local tail_bytes = tostring(archive_result.tail_bytes or "")
    local eocd_start
    for index = math.max(#tail_bytes - 21, 1), 1, -1 do
        if tail_bytes:sub(index, index + 3) == "PK\005\006" then
            eocd_start = index
            break
        end
    end
    if not eocd_start or #tail_bytes - eocd_start + 1 < 22 then
        return false
    end

    local comment_length = readUInt16LE(tail_bytes, eocd_start + 20)
    if not comment_length or eocd_start + 21 + comment_length ~= #tail_bytes then
        return false
    end

    local entry_count = readUInt16LE(tail_bytes, eocd_start + 10)
    local central_dir_size = readUInt32LE(tail_bytes, eocd_start + 12)
    local central_dir_offset = readUInt32LE(tail_bytes, eocd_start + 16)
    if not entry_count or not central_dir_size or not central_dir_offset then
        return false
    end

    local eocd_offset = archive_result.bytes - (#tail_bytes - eocd_start + 1)
    if eocd_offset < 0 or central_dir_offset + central_dir_size ~= eocd_offset then
        return false
    end
    if entry_count == 0 and central_dir_size == 0 then
        return false
    end
    if header_signature ~= "PK\003\004" or entry_count == 0 or central_dir_size == 0 or central_dir_offset <= 0 then
        return false
    end

    if central_dir_size < 46 then
        return false
    end
    local central_dir_bytes = readArchiveBytes(archive_result, archive_path, central_dir_offset, central_dir_size)
    if not central_dir_bytes then
        return false
    end

    local central_dir_end = central_dir_size
    local central_index = 1
    local entries = {}
    for _ = 1, entry_count do
        local entry = parseCentralDirectoryEntry(central_dir_bytes, central_index, central_dir_end)
        if not entry then
            return false
        end
        local local_header = parseLocalHeader(archive_result, archive_path, entry.local_header_offset)
        if not local_header then
            return false
        end
        local uses_data_descriptor = hasFlag(local_header.flags, 8)
        if uses_data_descriptor ~= hasFlag(entry.flags, 8)
            or entry.local_header_offset >= central_dir_offset
            or local_header.name_length ~= entry.name_length
            or entry.local_header_offset + local_header.header_length + entry.compressed_size > central_dir_offset
        then
            return false
        end
        if not uses_data_descriptor and local_header.compressed_size ~= entry.compressed_size then
            return false
        end
        table.insert(entries, {
            local_header_offset = entry.local_header_offset,
            payload_end = entry.local_header_offset + local_header.header_length + entry.compressed_size,
            uses_data_descriptor = uses_data_descriptor,
        })
        central_index = central_index + entry.length
    end
    if central_index ~= central_dir_end + 1 or #entries == 0 then
        return false
    end
    table.sort(entries, function(left, right)
        return left.local_header_offset < right.local_header_offset
    end)

    local previous_payload_end = 0
    local previous_uses_data_descriptor = false
    for _, entry in ipairs(entries) do
        local gap = entry.local_header_offset - previous_payload_end
        if not isAllowedDescriptorGap(previous_uses_data_descriptor, gap) then
            return false
        end
        previous_payload_end = entry.payload_end
        previous_uses_data_descriptor = entry.uses_data_descriptor
    end
    if not isAllowedDescriptorGap(previous_uses_data_descriptor, central_dir_offset - previous_payload_end) then
        return false
    end

    return true
end

function Downloader:finalizePartialArchive(partial_path, chapter_path, existing_path)
    local function finish(result)
        local manga_dir = tostring(chapter_path or ""):match("^(.*)/[^/]+$")
        if manga_dir and manga_dir ~= "" then
            self:pruneEmptyStagingDirectory(manga_dir)
        end
        return result
    end

    if existing_path then
        self:cleanupPartialFile(partial_path)
        return finish({
            ok = true,
            skipped = true,
            path = existing_path,
        })
    end

    local renamed, rename_error = os.rename(partial_path, chapter_path)
    if renamed then
        return finish({
            ok = true,
            path = chapter_path,
        })
    end

    if self:chapterExists(chapter_path) then
        self:cleanupPartialFile(partial_path)
        return finish({
            ok = true,
            skipped = true,
            path = chapter_path,
        })
    end

    self:cleanupPartialFile(partial_path)
    local error_message = "Could not finalize chapter archive."
    if rename_error and tostring(rename_error) ~= "" then
        error_message = error_message .. " " .. tostring(rename_error)
    end
    return finish({
        ok = false,
        error = error_message,
        path = chapter_path,
    })
end

function Downloader:downloadDirectChapterArchive(credentials, download_directory, manga, chapter)
    if not SuwayomiAPI.downloadChapterArchive or not chapter or chapter.id == nil then
        return nil
    end

    if not download_directory or download_directory == "" then
        return { ok = false, error = "Set up a download directory first." }
    end

    local manga_dir, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    local existing_path = self:findExistingChapterPath(download_directory, manga, chapter)
    if existing_path then
        return { ok = true, skipped = true, path = existing_path }
    end

    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error }
    end

    self:cleanupChapterStaging(chapter_path)
    local staging_ok, staging_error = self:ensureDirectory(self:getStagingDirectory(manga_dir))
    if not staging_ok then
        return { ok = false, error = staging_error or "Could not create download staging folder." }
    end
    local partial_path = self.getDirectPartialPath and self:getDirectPartialPath(chapter_path) or self:getPartialPath(chapter_path)

    local archive_result = callWithTransientRetry(function()
        return SuwayomiAPI.downloadChapterArchive(credentials, chapter.id, partial_path, {
            total_timeout_seconds = CHAPTER_ARCHIVE_TIMEOUT_SECONDS,
        })
    end)
    if not archive_result.ok then
        self:cleanupPartialFile(partial_path)
        return nil
    end
    if (archive_result.bytes or 0) <= 0
        or not self:isArchiveContentType(archive_result.content_type)
        or not self:isZipArchiveResult(archive_result, partial_path)
    then
        self:cleanupPartialFile(partial_path)
        return nil
    end

    return self:finalizePartialArchive(partial_path, chapter_path, self:findExistingChapterPath(download_directory, manga, chapter))
end

function Downloader:writeProgress(progress_path, state, current, total, path, error_message)
    if not progress_path or progress_path == "" then
        return
    end

    local tmp_path = tostring(progress_path) .. ".tmp"
    local handle = io.open(tmp_path, "w")
    if not handle then
        return
    end

    handle:write("state=", ProgressFile.lineSafe(state), "\n")
    handle:write("current=", ProgressFile.lineSafe(current or 0), "\n")
    handle:write("total=", ProgressFile.lineSafe(total or 0), "\n")
    handle:write("path=", ProgressFile.lineSafe(path), "\n")
    if error_message then
        handle:write("error=", ProgressFile.lineSafe(error_message), "\n")
    end
    handle:close()
    if not os.rename(tmp_path, progress_path) then
        os.remove(tmp_path)
    end
end

function Downloader:startChapterDownload(credentials, download_directory, manga, chapter)
    if not download_directory or download_directory == "" then
        return { ok = false, error = "Set up a download directory first." }
    end

    local manga_dir, chapter_path = self:getTargetPath(download_directory, manga, chapter)
    local existing_path = self:findExistingChapterPath(download_directory, manga, chapter)
    if existing_path then
        return { ok = true, skipped = true, path = existing_path }
    end
    local chapter_path_candidates = self:getChapterPathCandidates(download_directory, manga, chapter)
    local partial_path = self:getPartialPath(chapter_path)
    local pages_dir = tostring(partial_path) .. ".pages"

    local page_result = callWithTransientRetry(function()
        return SuwayomiAPI.fetchChapterPages(credentials, chapter.id)
    end)
    if not page_result.ok then
        return { ok = false, error = page_result.error }
    end
    if #page_result.pages == 0 then
        return { ok = false, error = "Suwayomi server did not return chapter pages." }
    end

    local directory_ok, directory_error = self:ensureDirectory(manga_dir)
    if not directory_ok then
        return { ok = false, error = directory_error }
    end

    local staging_dir = self:getStagingDirectory(manga_dir)
    local staging_ok, staging_error = self:ensureDirectory(staging_dir)
    if not staging_ok then
        return { ok = false, error = staging_error or "Could not create download staging folder." }
    end

    -- Cover download is deferred to writeSidecarsForChapter after the CBZ is
    -- ready. Doing it here blocked the UI event loop for a full binary GET.

    -- Drop any old visible partials from before hidden staging existed.
    self:cleanupChapterStaging(chapter_path)
    local pages_ok, pages_error = self:ensureDirectory(pages_dir)
    if not pages_ok then
        return { ok = false, error = pages_error or "Could not create chapter page folder." }
    end

    -- Kindle FSP often fails Archiver.Writer:addFileFromMemory with "Write error".
    -- Download pages to disk first; pack a STORED zip with plain file IO at the end.
    return {
        ok = true,
        path = chapter_path,
        total = #page_result.pages,
        job = {
            credentials = credentials,
            pages = page_result.pages,
            page_files = {},
            pages_dir = pages_dir,
            chapter_path = chapter_path,
            chapter_path_candidates = chapter_path_candidates,
            partial_path = partial_path,
            current = 0,
            written = 0,
        },
    }
end

function Downloader:validatePage(binary)
    if not binary.body or #binary.body == 0 then
        return false, "Downloaded chapter page was empty."
    end

    local content_type = tostring(binary.content_type or ""):lower()
    if not content_type:match("^image/") then
        return false, "Downloaded chapter page was not an image."
    end

    -- Reject Suwayomi UI cache blobs / HTML error pages mislabeled as images.
    local body = binary.body
    local b0, b1, b2 = body:byte(1, 3)
    local is_jpeg = b0 == 0xFF and b1 == 0xD8 and b2 == 0xFF
    local is_png = body:sub(1, 8) == "\137PNG\r\n\26\n"
    local is_webp = #body >= 12 and body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP"
    local is_gif = body:sub(1, 6) == "GIF87a" or body:sub(1, 6) == "GIF89a"
    if not (is_jpeg or is_png or is_webp or is_gif) then
        return false, "Downloaded chapter page had an invalid image header."
    end

    return true
end

function Downloader:packPageFiles(job)
    local files = {}
    for index = 1, #(job.page_files or {}) do
        local page_file = job.page_files[index]
        if not page_file or not page_file.path or lfs.attributes(page_file.path, "mode") ~= "file" then
            return {
                ok = false,
                error = "Chapter page files are incomplete.",
                current = job.current,
                total = #(job.pages or {}),
                path = job.chapter_path,
            }
        end
        files[#files + 1] = page_file
    end

    self:cleanupPartialFile(job.partial_path)
    local ok, err = writeStoredZipFromFiles(job.partial_path, files)
    if not ok then
        self:cleanupPartialFile(job.partial_path)
        return {
            ok = false,
            error = err or "Could not write chapter archive.",
            current = job.current,
            total = #(job.pages or {}),
            path = job.chapter_path,
        }
    end

    removeDirectoryTree(job.pages_dir)
    return self:finalizeChapterArchive(job)
end

function Downloader:finalizeChapterArchive(job)
    local function finish(result)
        local manga_dir = tostring(job and job.chapter_path or ""):match("^(.*)/[^/]+$")
        if manga_dir and manga_dir ~= "" then
            self:pruneEmptyStagingDirectory(manga_dir)
        end
        return result
    end

    local written = job.written
    if written == nil then
        written = job.current
    end

    if written ~= #job.pages then
        self:cleanupPartialFile(job.partial_path)
        removeDirectoryTree(job.pages_dir)
        return finish({
            ok = false,
            error = "Chapter archive page count did not match Suwayomi page count.",
            current = job.current,
            total = #job.pages,
            path = job.chapter_path,
        })
    end

    local existing_path = self:findExistingPathInCandidates(job.chapter_path_candidates)
    if existing_path then
        self:cleanupPartialFile(job.partial_path)
        removeDirectoryTree(job.pages_dir)
        return finish({
            ok = true,
            done = true,
            skipped = true,
            current = job.current,
            total = #job.pages,
            path = existing_path,
        })
    end

    local renamed, rename_error = os.rename(job.partial_path, job.chapter_path)
    if not renamed then
        if self:chapterExists(job.chapter_path) then
            self:cleanupPartialFile(job.partial_path)
            removeDirectoryTree(job.pages_dir)
            return finish({
                ok = true,
                done = true,
                skipped = true,
                current = job.current,
                total = #job.pages,
                path = job.chapter_path,
            })
        end
        self:cleanupPartialFile(job.partial_path)
        removeDirectoryTree(job.pages_dir)
        local error_message = "Could not finalize chapter archive."
        if rename_error and tostring(rename_error) ~= "" then
            error_message = error_message .. " " .. tostring(rename_error)
        end
        return finish({
            ok = false,
            error = error_message,
            current = job.current,
            total = #job.pages,
            path = job.chapter_path,
        })
    end

    removeDirectoryTree(job.pages_dir)
    return finish({
        ok = true,
        done = true,
        current = job.current,
        total = #job.pages,
        path = job.chapter_path,
    })
end

function Downloader:downloadNextPage(job)
    if not job or not job.pages then
        return { ok = false, error = "Invalid chapter download job." }
    end

    if job.current >= #job.pages then
        return self:packPageFiles(job)
    end

    local next_index = job.current + 1
    local binary = callWithTransientRetry(function()
        return SuwayomiAPI.downloadBinary(job.credentials, job.pages[next_index])
    end)
    if not binary.ok then
        removeDirectoryTree(job.pages_dir)
        return self:failAndCleanup(binary.error, job.partial_path, job.writer)
    end
    local valid_page, validation_error = self:validatePage(binary)
    if not valid_page then
        removeDirectoryTree(job.pages_dir)
        return self:failAndCleanup(validation_error, job.partial_path, job.writer)
    end

    local ext = binary.content_type == "image/webp" and "webp"
        or binary.content_type == "image/png" and "png"
        or "jpg"

    local entry_name = string.format("%04d.%s", next_index, ext)
    local page_path = (job.pages_dir or (tostring(job.partial_path) .. ".pages")) .. "/" .. entry_name
    local handle = io.open(page_path, "wb")
    if not handle then
        removeDirectoryTree(job.pages_dir)
        return self:failAndCleanup("Could not write chapter page to disk.", job.partial_path, job.writer)
    end
    local written_ok, write_err = handle:write(binary.body)
    handle:close()
    if written_ok == false then
        removeDirectoryTree(job.pages_dir)
        return self:failAndCleanup(
            "Could not write chapter page to disk. " .. tostring(write_err or "Write error"),
            job.partial_path,
            job.writer
        )
    end

    job.page_files = job.page_files or {}
    job.page_files[next_index] = { name = entry_name, path = page_path }
    job.current = next_index
    job.written = (job.written or 0) + 1
    if job.current == #job.pages then
        return self:packPageFiles(job)
    end

    return {
        ok = true,
        done = false,
        current = job.current,
        total = #job.pages,
        path = job.chapter_path,
    }
end

function Downloader:downloadChapter(credentials, download_directory, manga, chapter)
    local direct_result = self:downloadDirectChapterArchive(credentials, download_directory, manga, chapter)
    if direct_result then
        if direct_result.ok and direct_result.path then
            self:writeSidecarsForChapter(direct_result.path, manga, chapter, credentials)
        end
        return direct_result
    end

    local start_result = self:startChapterDownload(credentials, download_directory, manga, chapter)
    if not start_result.ok or start_result.skipped then
        if start_result.ok and start_result.path then
            self:writeSidecarsForChapter(start_result.path, manga, chapter, credentials)
        end
        return start_result
    end

    local result
    repeat
        result = self:downloadNextPage(start_result.job)
        if not result.ok then
            return result
        end
    until result.done

    local final_path = (result and result.path) or start_result.path
    if final_path then
        self:writeSidecarsForChapter(final_path, manga, chapter, credentials)
    end
    return { ok = true, skipped = result and result.skipped, path = final_path }
end

function Downloader:downloadChapterWithProgress(credentials, download_directory, manga, chapter, progress_path)
    local direct_result = self:downloadDirectChapterArchive(credentials, download_directory, manga, chapter)
    if direct_result then
        if direct_result.ok and direct_result.path then
            self:writeSidecarsForChapter(direct_result.path, manga, chapter, credentials)
        end
        self:writeProgress(
            progress_path,
            direct_result.skipped and "skipped" or (direct_result.ok and "downloaded" or "failed"),
            direct_result.ok and 1 or 0,
            direct_result.ok and 1 or 0,
            direct_result.path,
            direct_result.error
        )
        return direct_result
    end

    local start_result = self:startChapterDownload(credentials, download_directory, manga, chapter)
    if not start_result.ok or start_result.skipped then
        if start_result.ok and start_result.path then
            self:writeSidecarsForChapter(start_result.path, manga, chapter, credentials)
        end
        self:writeProgress(
            progress_path,
            start_result.skipped and "skipped" or (start_result.ok and "downloaded" or "failed"),
            start_result.ok and 1 or 0,
            start_result.ok and 1 or 0,
            start_result.path,
            start_result.error
        )
        return start_result
    end

    local result
    repeat
        result = self:downloadNextPage(start_result.job)
        if not result.ok then
            self:writeProgress(progress_path, "failed", 0, start_result.total, start_result.path, result.error)
            return result
        end
        self:writeProgress(
            progress_path,
            result.skipped and "skipped" or (result.done and "downloaded" or "downloading"),
            result.current,
            result.total,
            result.path
        )
    until result.done

    local final_path = (result and result.path) or start_result.path
    if final_path then
        self:writeSidecarsForChapter(final_path, manga, chapter, credentials)
    end
    return { ok = true, skipped = result and result.skipped, path = final_path }
end

return Downloader
