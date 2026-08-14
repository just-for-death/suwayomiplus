-- Boundary: cached chapter reading through KOReader's document reader.
--
-- Responsibility: pull a chapter into a size-capped cache, open it as a real
-- document so history/statistics apply, keep the cache under its limit, and
-- move between chapters from inside the reader.
-- Owned state: pending-open token and reader navigation state on the plugin.
-- Dependencies: download queue, downloader path helpers, settings, KOReader
-- reader UI and UIManager.
-- External data: filesystem entries, persisted chapter lists, and queue status
-- are validated before use.

local DataStorage = require("datastorage")
local I18n = require("suwayomi/i18n")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local UIManager = require("ui/uimanager")
local lfs = require("suwayomi/fs")

local CacheReader = {}
CacheReader.__index = CacheReader

function CacheReader:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

-- Kept outside KOReader's own cache/ tree, which its document cache prunes on
-- its own terms.
local CACHE_DIRECTORY_NAME = "suwayomi_chapters"
local PENDING_OPEN_POLL_SECONDS = 1
local PENDING_OPEN_TIMEOUT_SECONDS = 600
local PREFETCH_DELAY_SECONDS = 6
local MAX_CACHE_SCAN_DEPTH = 4
local STALE_LEFTOVER_SECONDS = 60
local PRUNE_DELAY_SECONDS = 5

local function chapterKey(chapter)
    return chapter and tostring(chapter.id or "") or ""
end

local function bytesForMegabytes(megabytes)
    return math.floor((tonumber(megabytes) or 0) * 1024 * 1024)
end

local function isCbzName(name)
    return type(name) == "string" and name:lower():match("%.cbz$") ~= nil
end

local function isLeftoverName(name)
    if type(name) ~= "string" then
        return false
    end
    local lowered = name:lower()
    return lowered:match("%.part$") ~= nil
        or lowered:match("%.tmp$") ~= nil
        or lowered:match("^%.suwayomi") ~= nil
end

-- KOReader reports "." as the data dir on Kindle. Reader history, sidecars and
-- the download queue all persist this path, so it has to be absolute.
function Methods:getChapterCacheRoot()
    local root
    if DataStorage.getFullDataDir then
        local ok, full = pcall(function()
            return DataStorage:getFullDataDir()
        end)
        if ok and type(full) == "string" and full ~= "" then
            root = full
        end
    end
    if not root or root:sub(1, 1) ~= "/" then
        local data_dir = DataStorage:getDataDir()
        if type(data_dir) == "string" and data_dir:sub(1, 1) == "/" then
            root = data_dir
        else
            root = lfs.currentdir()
        end
    end
    if type(root) ~= "string" or root == "" then
        return nil
    end
    return (root:gsub("/+$", ""))
end

function Methods:getChapterCacheDirectory()
    local root = self:getChapterCacheRoot()
    if not root then
        return nil
    end
    local Downloader = require("suwayomi/downloads/downloader")
    local directory = root .. "/" .. CACHE_DIRECTORY_NAME
    if not Downloader:ensureDirectory(directory) then
        return nil
    end
    return directory
end

function Methods:findCachedChapterPath(manga, chapter)
    local directory = self:getChapterCacheDirectory()
    if not directory then
        return nil
    end
    local Downloader = require("suwayomi/downloads/downloader")
    return Downloader:findExistingChapterPath(directory, manga, chapter)
end

-- The cache mirrors the download layout, <cache>/<source>/<manga>/<chapter>.cbz,
-- so the scan has to walk down rather than assume a fixed depth.
function Methods:scanChapterCache()
    local directory = self:getChapterCacheDirectory()
    local result = {
        chapters = {},
        leftovers = {},
        directories = {},
    }
    if not directory then
        return result
    end

    local function walk(current, depth)
        if depth > MAX_CACHE_SCAN_DEPTH then
            return
        end
        local ok, iterator = pcall(lfs.dir, current)
        if not ok then
            return
        end
        for name in iterator do
            if name ~= "." and name ~= ".." then
                local path = current .. "/" .. name
                local attributes = lfs.attributes(path)
                if attributes and attributes.mode == "directory" then
                    table.insert(result.directories, path)
                    walk(path, depth + 1)
                elseif attributes and attributes.mode == "file" then
                    if isCbzName(name) then
                        table.insert(result.chapters, {
                            path = path,
                            directory = current,
                            size = attributes.size or 0,
                            modified_at = attributes.modification or 0,
                        })
                    elseif isLeftoverName(name) then
                        table.insert(result.leftovers, {
                            path = path,
                            directory = current,
                            size = attributes.size or 0,
                            modified_at = attributes.modification or 0,
                        })
                    end
                end
            end
        end
    end

    walk(directory, 1)
    return result
end

function Methods:listCachedChapterEntries()
    return self:scanChapterCache().chapters
end

-- A running download owns its .part and progress files, so leftovers are only
-- safe to delete once the queue is idle and the files have gone quiet.
function Methods:removeStaleCacheLeftovers(scan)
    local queue = self:getDownloadQueue()
    if queue:getActiveCount() > 0 or #(queue.items or {}) > 0 then
        return 0, 0
    end

    local now = os.time()
    local removed = 0
    local reclaimed = 0
    for _, entry in ipairs(scan.leftovers or {}) do
        if now - (entry.modified_at or 0) >= STALE_LEFTOVER_SECONDS and os.remove(entry.path) then
            removed = removed + 1
            reclaimed = reclaimed + entry.size
        end
    end
    return removed, reclaimed
end

-- Cache jobs recorded against a different cache path (an older relative one, for
-- instance) can never resolve, so they would sit in the queue as permanent
-- failures.
function Methods:purgeStaleCacheJobs()
    local directory = self:getChapterCacheDirectory()
    if not directory then
        return 0
    end

    local queue = self:getDownloadQueue()
    local kept = {}
    local dropped = {}
    for _, job in ipairs(queue:loadPersistentJobs()) do
        local job_directory = type(job.download_directory) == "string" and job.download_directory or ""
        if job_directory ~= directory and job_directory:match(CACHE_DIRECTORY_NAME .. "/?$") then
            table.insert(dropped, job)
        else
            table.insert(kept, job)
        end
    end

    if #dropped == 0 then
        return 0
    end

    queue:savePersistentJobs(kept)
    for _, job in ipairs(dropped) do
        if job.manga and job.chapter then
            queue:clearStatus(job.manga, job.chapter, { quiet = true })
        end
    end
    self:refreshChapterMenu({ quick = true })
    return #dropped
end

-- Interrupted fetches leave .part files behind that no later run will resume.
function Methods:cleanupChapterCacheLeftovers()
    self:purgeStaleCacheJobs()
    local scan = self:scanChapterCache()
    local removed = self:removeStaleCacheLeftovers(scan)
    self:removeEmptyCacheDirectories(scan.directories)
    return removed
end

-- Deepest first, so a manga folder can go once its chapters are gone.
function Methods:removeEmptyCacheDirectories(directories)
    local sorted = {}
    for _, path in ipairs(directories or {}) do
        table.insert(sorted, path)
    end
    table.sort(sorted, function(left, right)
        return #left > #right
    end)
    for _, path in ipairs(sorted) do
        os.remove(path)
    end
end

function Methods:getChapterCacheUsageBytes()
    local total = 0
    for _, entry in ipairs(self:listCachedChapterEntries()) do
        total = total + entry.size
    end
    return total
end

function Methods:removeCachedChapter(entry)
    local metadata_path = self.getKoreaderMetadataPathForDocument
        and self:getKoreaderMetadataPathForDocument(entry.path)
        or nil
    if self.removeChapterArchiveAndSidecars then
        return self:removeChapterArchiveAndSidecars(entry.path, metadata_path)
    end
    os.remove(entry.path)
    return lfs.attributes(entry.path, "mode") ~= "file"
end

-- Oldest-first eviction: reading a cached chapter refreshes its timestamp, so
-- the chapters you keep coming back to survive.
function Methods:pruneChapterCache(keep_paths)
    local limit_bytes = bytesForMegabytes(SuwayomiSettings:loadChapterCacheLimitMB())
    if limit_bytes <= 0 then
        return 0
    end

    local protected = {}
    for _, path in ipairs(keep_paths or {}) do
        if type(path) == "string" and path ~= "" then
            protected[path] = true
        end
    end
    local current_document = self.getCurrentReaderDocumentPath and self:getCurrentReaderDocumentPath() or nil
    if current_document then
        protected[current_document] = true
    end

    local scan = self:scanChapterCache()
    local entries = scan.chapters
    local total = 0
    for _, entry in ipairs(entries) do
        total = total + entry.size
    end
    for _, entry in ipairs(scan.leftovers) do
        total = total + entry.size
    end
    if total <= limit_bytes then
        return 0
    end

    local _removed_leftovers, reclaimed = self:removeStaleCacheLeftovers(scan)
    total = total - reclaimed

    table.sort(entries, function(left, right)
        return left.modified_at < right.modified_at
    end)

    local removed = 0
    for _, entry in ipairs(entries) do
        if total <= limit_bytes then
            break
        end
        if not protected[entry.path] and self:removeCachedChapter(entry) then
            total = total - entry.size
            removed = removed + 1
        end
    end

    self:removeEmptyCacheDirectories(scan.directories)
    return removed
end

function Methods:schedulePruneChapterCache(keep_paths)
    UIManager:scheduleIn(PRUNE_DELAY_SECONDS, function()
        pcall(function()
            self:pruneChapterCache(keep_paths)
        end)
    end)
end

function Methods:clearChapterCache()
    local scan = self:scanChapterCache()
    local removed = 0
    local current_document = self.getCurrentReaderDocumentPath and self:getCurrentReaderDocumentPath() or nil
    self:removeStaleCacheLeftovers(scan)
    for _, entry in ipairs(scan.chapters) do
        if entry.path ~= current_document and self:removeCachedChapter(entry) then
            removed = removed + 1
        end
    end
    self:removeEmptyCacheDirectories(scan.directories)
    return removed
end

function Methods:touchCachedChapter(path)
    if not path or path == "" or not lfs.touch then
        return false
    end
    local ok = pcall(lfs.touch, path, os.time())
    return ok == true
end

function Methods:rememberReaderChapterList(manga, chapters)
    if not manga or manga.id == nil then
        return nil
    end

    if type(chapters) ~= "table" or #chapters == 0 then
        local context = self.current_chapter_context
        if context and context.manga and tostring(context.manga.id or "") == tostring(manga.id) then
            chapters = context.chapters or {}
            if self.getVisibleChapters then
                chapters = self:getVisibleChapters(chapters) or chapters
            end
        end
    end
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil
    end
    return SuwayomiSettings:saveReaderChapterList(manga, chapters)
end

-- History, sidecars and collections key off the document path, so a relative
-- one would follow the working directory instead of the file.
function Methods:toAbsoluteDocumentPath(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
        return path
    end
    local current = lfs.currentdir()
    if type(current) ~= "string" or current == "" then
        return path
    end
    return (current:gsub("/+$", "")) .. "/" .. (path:gsub("^%./", ""))
end

function Methods:openChapterDocument(manga, chapter, chapter_path, options)
    options = options or {}
    chapter_path = self:toAbsoluteDocumentPath(chapter_path)
    if not chapter_path or chapter_path == "" then
        self:showMessage(I18n.t("KOReader could not open this chapter right now."))
        return false
    end

    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then
        self:showMessage(I18n.t("KOReader could not open this chapter right now."))
        return false
    end

    if self.saveReaderReturnContext then
        self:saveReaderReturnContext(manga, chapter, chapter_path)
    end
    if self.upsertChapterLedgerEntry then
        self:upsertChapterLedgerEntry(manga, chapter, {
            path = chapter_path,
        })
    end
    self:rememberReaderChapterList(manga, options.chapters)
    self:touchCachedChapter(chapter_path)
    -- Pruning walks the whole cache tree and deletes files, which must not sit
    -- between the tap and the document appearing.
    self:schedulePruneChapterCache({ chapter_path })

    if ReaderUI.instance and ReaderUI.instance.switchDocument then
        ReaderUI.instance:switchDocument(chapter_path)
    elseif ReaderUI.showReader then
        ReaderUI:showReader(chapter_path)
    else
        self:showMessage(I18n.t("KOReader could not open this chapter right now."))
        return false
    end
    return true
end

function Methods:cancelPendingChapterOpen()
    local pending = self.pending_chapter_open
    if not pending then
        return false
    end
    self.pending_chapter_open = nil
    return true
end

function Methods:watchPendingChapterOpen(token)
    UIManager:scheduleIn(PENDING_OPEN_POLL_SECONDS, function()
        if self.pending_chapter_open ~= token then
            return
        end
        -- A cleared status means the download failed or was cancelled from the
        -- chapter menu; either way nothing is going to open.
        local status = self:getDownloadQueue():getStatus(token.manga, token.chapter)
        if not status or status.state == "failed" then
            self.pending_chapter_open = nil
            return
        end
        if os.time() - token.started_at > PENDING_OPEN_TIMEOUT_SECONDS then
            self.pending_chapter_open = nil
            self:showMessage(I18n.t("Preparing this chapter took too long."))
            return
        end
        self:watchPendingChapterOpen(token)
    end)
end

function Methods:openChapterForTap(manga, chapter)
    if SuwayomiSettings:loadChapterTapAction() == "reader" then
        return self:readChapter(manga, chapter)
    end
    if self.streamChapter then
        return self:streamChapter(manga, chapter)
    end
    return self:readChapter(manga, chapter)
end

function Methods:requestChapterIntoCache(manga, chapter, options)
    options = options or {}
    local directory = self:getChapterCacheDirectory()
    if not directory then
        self:showMessage(I18n.t("Could not create the chapter cache folder."))
        return false
    end

    if options.open then
        self:cancelPendingChapterOpen()
        local token = {
            manga = manga,
            chapter = chapter,
            key = chapterKey(chapter),
            chapters = options.chapters,
            started_at = os.time(),
        }
        self.pending_chapter_open = token
        self:showMessage(
            I18n.t("Fetching the whole chapter, it opens by itself when ready. Progress shows on the chapter row."),
            { timeout = 4 }
        )
        self:watchPendingChapterOpen(token)
    end

    self:withChapterMenuRefreshSuppressed(function()
        self:getDownloadQueue():enqueue(manga, chapter, directory, {
            quiet_duplicate = true,
            purpose = "cache",
        })
    end)
    self:refreshChapterMenu({ quick = true })
    return true
end

function Methods:isCachedChapterPath(chapter_path)
    if type(chapter_path) ~= "string" or chapter_path == "" then
        return false
    end
    local directory = self:getChapterCacheDirectory()
    if not directory then
        return false
    end
    return chapter_path:sub(1, #directory + 1) == directory .. "/"
end

function Methods:handleChapterArchiveReady(manga, chapter, chapter_path)
    if self:isCachedChapterPath(chapter_path) then
        -- A cached chapter is not a library download, so the chapter row should
        -- not keep showing a download badge once the fetch completes.
        self:getDownloadQueue():clearStatus(manga, chapter, { quiet = true })
        self:refreshChapterMenu({ quick = true })
    end

    local pending = self.pending_chapter_open
    if not pending or pending.key ~= chapterKey(chapter) then
        return false
    end
    self.pending_chapter_open = nil
    return self:openChapterDocument(pending.manga or manga, chapter, chapter_path, {
        chapters = pending.chapters,
    })
end

function Methods:readChapter(manga, chapter, options)
    options = options or {}
    if not manga or not chapter or chapter.id == nil then
        self:showMessage(I18n.t("Could not open this chapter."))
        return false
    end

    self:rememberReaderChapterList(manga, options.chapters)

    local downloaded, downloaded_path = self:isChapterDownloaded(manga, chapter)
    if downloaded and downloaded_path then
        return self:openChapterDocument(manga, chapter, downloaded_path, options)
    end

    local cached_path = self:findCachedChapterPath(manga, chapter)
    if cached_path then
        return self:openChapterDocument(manga, chapter, cached_path, options)
    end

    local credentials = SuwayomiSettings:load()
    if not credentials.server_url or credentials.server_url == "" then
        self:showMessage(I18n.t("Set your Suwayomi server URL first."))
        return false
    end

    return self:requestChapterIntoCache(manga, chapter, {
        open = true,
        chapters = options.chapters,
    })
end

-- Reader-side navigation. The reader owns a separate plugin instance with no
-- chapter menu, so the ordered chapter list comes from settings.

function Methods:getReaderChapterNavigation()
    local context = self.getCurrentReaderReturnContext and self:getCurrentReaderReturnContext() or nil
    if not context or not context.manga_id then
        return nil
    end

    local list = SuwayomiSettings:loadReaderChapterList(context.manga_id)
    if not list then
        return context
    end

    local target = tostring(context.chapter_id or "")
    for index, entry in ipairs(list.chapters) do
        if tostring(entry.id) == target then
            return context, list, index
        end
    end
    return context, list
end

function Methods:hasReaderChapterNavigation()
    local _context, list, index = self:getReaderChapterNavigation()
    return list ~= nil and index ~= nil
end

function Methods:buildReaderNavigationManga(context, list)
    return {
        id = context.manga_id,
        title = context.manga_title or (list and list.manga_title) or context.manga_id,
        in_library = context.in_library,
        source = context.source,
    }
end

function Methods:markReaderChapterRead(manga, list, index)
    local entry = list and list.chapters[index]
    if not entry or entry.is_read == true then
        return false
    end

    self:markChapterRead(manga, { id = entry.id, name = entry.name }, {
        skip_refresh = true,
        skip_delete_after_mark_read = true,
    })
    entry.is_read = true
    SuwayomiSettings:saveReaderChapterList(manga, list.chapters)
    return true
end

function Methods:openReaderChapterEntry(manga, list, entry)
    if not entry then
        return false
    end
    return self:readChapter(manga, {
        id = entry.id,
        name = entry.name,
        is_read = entry.is_read,
    }, {
        chapters = list and list.chapters or nil,
    })
end

function Methods:openAdjacentChapterFromReader(delta)
    local context, list, index = self:getReaderChapterNavigation()
    if not context then
        self:showMessage(I18n.t("This book is not linked to Suwayomi chapters."))
        return false
    end
    if not list or not index then
        self:showMessage(I18n.t("Open this manga in Suwayomi once to enable chapter navigation."))
        return false
    end

    local target = list.chapters[index + delta]
    if not target then
        self:showMessage(delta > 0 and I18n.t("No next chapter.") or I18n.t("No previous chapter."))
        return false
    end

    local manga = self:buildReaderNavigationManga(context, list)
    if delta > 0 then
        self:markReaderChapterRead(manga, list, index)
    end
    return self:openReaderChapterEntry(manga, list, target)
end

function Methods:showReaderChapterPicker()
    local context, list, index = self:getReaderChapterNavigation()
    if not context or not list then
        self:showMessage(I18n.t("Open this manga in Suwayomi once to enable chapter navigation."))
        return false
    end

    local manga = self:buildReaderNavigationManga(context, list)
    local items = {}
    for entry_index, entry in ipairs(list.chapters) do
        local status
        if entry_index == index then
            status = I18n.c("chapter status", "reading")
        elseif entry.is_read == true then
            status = I18n.c("chapter status", "read")
        end
        items[entry_index] = {
            id = entry.id,
            name = entry.name,
            is_read = entry.is_read,
            menu_status = status,
        }
    end

    local menu
    menu = SuwayomiUI.showChapterMenu({
        title = list.manga_title or I18n.t("Chapters"),
        chapters = items,
        itemnumber = index,
    }, function(entry)
        UIManager:close(menu)
        self:openReaderChapterEntry(manga, list, entry)
    end)
    return true
end

function Methods:showReaderEndOfChapterMenu()
    local context, list, index = self:getReaderChapterNavigation()
    if not context or not list or not index then
        return false
    end

    local manga = self:buildReaderNavigationManga(context, list)
    self:markReaderChapterRead(manga, list, index)

    local actions = {}
    if list.chapters[index + 1] then
        table.insert(actions, { id = "next", text = I18n.t("Next chapter") })
    end
    if list.chapters[index - 1] then
        table.insert(actions, { id = "previous", text = I18n.t("Previous chapter") })
    end
    table.insert(actions, { id = "chapters", text = I18n.t("Chapter list") })
    table.insert(actions, { id = "suwayomi", text = I18n.t("Go to Suwayomi") })

    SuwayomiUI.showActionMenu({
        title = I18n.t("End of chapter"),
        actions = actions,
        vertical = true,
    }, function(action)
        if not action then
            return
        end
        if action.id == "next" then
            self:openReaderChapterEntry(manga, list, list.chapters[index + 1])
        elseif action.id == "previous" then
            self:openReaderChapterEntry(manga, list, list.chapters[index - 1])
        elseif action.id == "chapters" then
            self:showReaderChapterPicker()
        elseif action.id == "suwayomi" then
            self:returnToSuwayomiChapters()
        end
    end)
    return true
end

-- ReaderStatus claims the EndOfBook event before plugins see it, so the
-- instance method is wrapped while a Suwayomi chapter is open.
function Methods:installReaderEndOfChapterHook()
    local status = self.ui and self.ui.status
    if not status or self.reader_end_of_chapter_hooked then
        return false
    end

    local plugin = self
    local original = status.onEndOfBook
    self.reader_end_of_chapter_hooked = true
    status.onEndOfBook = function(status_self, ...)
        if plugin:hasReaderChapterNavigation() then
            if status_self.markBook then
                pcall(status_self.markBook, status_self, true)
            end
            if plugin:showReaderEndOfChapterMenu() then
                return true
            end
        end
        if original then
            return original(status_self, ...)
        end
        return false
    end
    return true
end

function Methods:prefetchNextChapterIntoCache()
    local context, list, index = self:getReaderChapterNavigation()
    if not context or not list or not index then
        return false
    end

    local next_entry = list.chapters[index + 1]
    if not next_entry then
        return false
    end

    local manga = self:buildReaderNavigationManga(context, list)
    local chapter = { id = next_entry.id, name = next_entry.name }
    if self:isChapterDownloaded(manga, chapter) or self:findCachedChapterPath(manga, chapter) then
        return false
    end

    return self:requestChapterIntoCache(manga, chapter, { open = false })
end

function Methods:scheduleNextChapterPrefetch()
    UIManager:scheduleIn(PREFETCH_DELAY_SECONDS, function()
        if not self.ui or not self.ui.document then
            return
        end
        pcall(function()
            self:prefetchNextChapterIntoCache()
        end)
    end)
end

function Methods:onSuwayomiNextChapter()
    self:openAdjacentChapterFromReader(1)
    return true
end

function Methods:onSuwayomiPreviousChapter()
    self:openAdjacentChapterFromReader(-1)
    return true
end

function Methods:onSuwayomiChapterList()
    self:showReaderChapterPicker()
    return true
end

CacheReader.methods = Methods

return CacheReader
