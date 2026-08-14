-- Boundary: server-backed chapter read actions.

local ChapterReadActions = {}
ChapterReadActions.__index = ChapterReadActions

function ChapterReadActions:new(deps)
    return setmetatable({ plugin = (deps or {}).plugin }, self)
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
    self:schedulePendingReadSync()
    return true
end

function Methods:markChapterRead(manga, chapter, options)
    options = options or {}
    local updates = {
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
    if not options.skip_refresh then
        self:refreshChapterMenu()
    end
    if not options.skip_schedule then
        self:schedulePendingReadSync()
    end
    return true
end

function Methods:markChapterUnread(manga, chapter, options)
    options = options or {}
    local updates = {
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
    return true
end

function Methods:markChapterListRead(manga, chapters)
    if #(chapters or {}) == 0 then
        return 0
    end
    local ledger = self:loadChapterLedger()
    for _, chapter in ipairs(chapters) do
        self:markChapterRead(manga, chapter, {
            ledger = ledger,
            skip_refresh = true,
            skip_schedule = true,
        })
    end
    self:saveChapterLedger(ledger)
    self:refreshChapterMenu({ ledger = ledger })
    self:schedulePendingReadSync()
    return #chapters
end

function Methods:markChaptersBeforeRead(manga, chapter)
    return self:markChapterListRead(manga, self:getChaptersBefore(chapter))
end

ChapterReadActions.methods = Methods
return ChapterReadActions
