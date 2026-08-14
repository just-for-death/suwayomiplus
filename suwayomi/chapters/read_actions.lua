-- Boundary: ChapterReadActions.
--
-- Responsibility: Mark chapters read/unread and coordinate local metadata, ledger,
-- page-progress, and read-sync side effects (including download keep/delete policies).
-- Owned state: Mutates current chapter context and settings-backed read ledger through plugin methods.
-- Dependencies: Plugin mixin methods and Suwayomi debug timing.
-- External data: Manga/chapter tables may come from API responses or cached UI state and are matched by stable ids.

local SuwayomiDebug = require("suwayomi/debug")

local ChapterReadActions = {}
ChapterReadActions.__index = ChapterReadActions

function ChapterReadActions:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function updateContext(owner, chapter, is_read)
    local context = owner.current_chapter_context
    for _, current in ipairs(context and context.chapters or {}) do
        if tostring(current.id or "") == tostring(chapter and chapter.id or "") then
            current.is_read = is_read
            return
        end
    end
end

function Methods:updateChapterProgress(manga, chapter, last_page_read)
    last_page_read = math.max(0, math.floor(tonumber(last_page_read) or 0))
    if not manga or not chapter or chapter.id == nil then
        return false
    end
    self:upsertChapterLedgerEntry(manga, chapter, {
        read = chapter.is_read == true,
        pending_read_sync = true,
        pending_read_state = chapter.is_read == true,
        pending_last_page_read = last_page_read,
    })
    chapter.last_page_read = last_page_read
    local context = self.current_chapter_context
    for _, current in ipairs(context and context.chapters or {}) do
        if tostring(current.id or "") == tostring(chapter.id) then
            current.last_page_read = last_page_read
            break
        end
    end
    self:schedulePendingReadSync(nil, 0)
    return true
end

function Methods:markChapterRead(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, true)
    end
    -- isChapterDownloaded returns the path it would use even when the file is
    -- absent, and a chapter read online has no local file at all.
    local updates = {
        path = downloaded and chapter_path or nil,
        read = true,
        pending_read_sync = true,
        pending_read_state = true,
        pending_last_page_read = tonumber(options.last_page_read),
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    chapter.is_read = true
    updateContext(self, chapter, true)
    local deleted_after_mark_read = 0
    if not options.skip_delete_after_mark_read and self.deleteChaptersAfterManualMarkRead then
        deleted_after_mark_read = self:deleteChaptersAfterManualMarkRead(manga, { chapter }, {
            ledger = options.ledger,
        })
    end
    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync(nil, 0)
        if manga and self.syncMangaTrackProgress then
            self:syncMangaTrackProgress(manga)
        end
    end
    if not options.skip_keep_policy and self.applyMangaKeepNextUnreadDownloadsPolicy then
        self:applyMangaKeepNextUnreadDownloadsPolicy(manga)
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterRead",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            deleted_after_mark_read = deleted_after_mark_read,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end

function Methods:markChapterUnread(manga, chapter, options)
    local started_at = SuwayomiDebug.now()
    options = options or {}
    local downloaded, chapter_path = self:isChapterDownloaded(manga, chapter)
    local metadata_updated = false
    if downloaded and chapter_path then
        metadata_updated = self:setKoreaderChapterReadState(chapter_path, false)
    end
    local updates = {
        path = downloaded and chapter_path or nil,
        read = false,
        pending_read_sync = true,
        pending_read_state = false,
        pending_last_page_read = nil,
    }
    if options.ledger then
        self:upsertChapterLedgerEntryInLedger(options.ledger, manga, chapter, updates)
    else
        self:upsertChapterLedgerEntry(manga, chapter, updates)
    end

    chapter.is_read = false
    updateContext(self, chapter, false)

    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    if not options.skip_refresh or not options.skip_schedule then
        SuwayomiDebug.log({
            operation = "markChapterUnread",
            event = "end",
            manga_id = manga and manga.id,
            chapter_id = chapter and chapter.id,
            downloaded = downloaded == true,
            metadata_updated = metadata_updated == true,
            skip_refresh = options.skip_refresh == true,
            skip_schedule = options.skip_schedule == true,
            elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
        })
    end
    return true
end

function Methods:markChapterListRead(manga, chapters)
    local started_at = SuwayomiDebug.now()
    if #(chapters or {}) == 0 then
        return 0
    end

    local ledger = self:loadChapterLedger()
    for _, chapter in ipairs(chapters) do
        self:markChapterRead(manga, chapter, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
            skip_keep_policy = true,
        })
    end

    self:saveChapterLedger(ledger)
    self:refreshChapterMenu({ ledger = ledger })
    self:schedulePendingReadSync()
    if self.applyMangaKeepNextUnreadDownloadsPolicy then
        self:applyMangaKeepNextUnreadDownloadsPolicy(manga)
    end
    SuwayomiDebug.log({
        operation = "markChapterListRead",
        event = "end",
        manga_id = manga and manga.id,
        chapter_count = #chapters,
        elapsed_ms = SuwayomiDebug.elapsedMs(started_at),
    })
    return #chapters
end

function Methods:markChaptersBeforeRead(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersBefore(chapter))
end

ChapterReadActions.methods = Methods

return ChapterReadActions
