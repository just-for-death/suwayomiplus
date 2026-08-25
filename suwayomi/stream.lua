-- Boundary: online chapter streaming (no local CBZ).
--
-- Responsibility: fetch page URLs from Suwayomi, prefetch nearby pages, show
-- them in ImageViewer, and move between chapters without downloading archives.
-- Owned state: stream session (manga/chapter/pages/viewer/cache) on the plugin.
-- Dependencies: Suwayomi API/settings, KOReader ImageViewer/NetworkMgr/UI.
-- External data: page URLs and image bytes from the Suwayomi server.

local I18n = require("suwayomi/i18n")
local NetworkRequestJob = require("suwayomi/network/request_job")
local SuwayomiAPI = require("suwayomi/api")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local UIManager = require("ui/uimanager")
local BD = require("ui/bidi")

local Stream = {}
Stream.__index = Stream

function Stream:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}
local PREFETCH_AHEAD = 5
local PAGE_CACHE_LIMIT = 12
-- Page fetches block the UI thread, so prefetch does one page per tick and
-- leaves room in between for KOReader to service input.
local PREFETCH_INTERVAL_SECONDS = 0.1
local PAGE_TIMEOUT_SECONDS = 30

local function runWhenOnline(callback)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(callback)
        return
    end
    callback()
end

local function renderPage(data)
    local RenderImage = require("ui/renderimage")
    if type(data) == "string" and #data > 0 then
        local page_bb = RenderImage:renderImageData(data, #data, false)
        if page_bb then
            return page_bb
        end
    end
    return RenderImage:renderImageFile("resources/koreader.png", false)
end

local function chapterKey(chapter)
    return chapter and tostring(chapter.id or "") or ""
end

-- Deferred work (waiting for Wi-Fi, prefetch ticks) captures this and bails if
-- the session it belongs to has since been cancelled or closed.
function Methods:getStreamGeneration()
    return self.stream_generation or 0
end

function Methods:invalidateStreamGeneration()
    self.stream_generation = (self.stream_generation or 0) + 1
    return self.stream_generation
end

function Methods:cancelChapterStreamRequest()
    local request = self.active_chapter_stream_request
    if not request then
        return false
    end
    self.active_chapter_stream_request = nil
    if request.active and NetworkRequestJob.cancel then
        NetworkRequestJob.cancel(request.active)
    end
    return true
end

-- The chapter menu may already be gone once pages arrive, so the active stream
-- keeps its own chapter-order snapshot.
function Methods:getStreamChapters(manga)
    manga = manga or (self.stream_session and self.stream_session.manga)
    local context = self.current_chapter_context
    -- A context left over from another title would hand the viewer the wrong
    -- next/previous chapters, so it only counts when it matches what is open.
    local context_matches = context
        and context.manga
        and (not manga or tostring(context.manga.id or "") == tostring(manga.id or ""))
    if self.getVisibleChapters and context_matches and type(context.chapters) == "table" and #context.chapters > 0 then
        return self:getVisibleChapters(context.chapters) or {}
    end
    local session = self.stream_session
    if session and type(session.chapters) == "table" and #session.chapters > 0 then
        return session.chapters
    end
    return {}
end

function Methods:rememberStreamChapterList(manga, chapters)
    if type(chapters) ~= "table" or #chapters == 0 then
        chapters = self:getStreamChapters(manga)
    end
    return chapters
end

function Methods:getStreamChapterIndex(chapter, manga)
    local target = chapterKey(chapter)
    for index, current in ipairs(self:getStreamChapters(manga)) do
        if chapterKey(current) == target then
            return index, current
        end
    end
    return nil
end

function Methods:getAdjacentStreamChapter(delta)
    local session = self.stream_session
    if not session or not session.chapter then
        return nil
    end
    local index = self:getStreamChapterIndex(session.chapter, session.manga)
    if not index then
        return nil
    end
    return self:getStreamChapters(session.manga)[index + delta]
end

function Methods:rememberStreamPageCache(chapter_id, pages)
    self.stream_page_lists = self.stream_page_lists or {}
    if chapter_id and type(pages) == "table" then
        self.stream_page_lists[tostring(chapter_id)] = pages
    end
end

function Methods:trimStreamImageCache(cache, keep_index)
    local keys = {}
    for key in pairs(cache) do
        if type(key) == "number" then
            table.insert(keys, key)
        end
    end
    table.sort(keys, function(a, b)
        return math.abs(a - keep_index) > math.abs(b - keep_index)
    end)
    while #keys > PAGE_CACHE_LIMIT do
        cache[keys[1]] = nil
        table.remove(keys, 1)
    end
end

function Methods:downloadStreamPageBytes(pages, index, cache)
    if type(index) ~= "number" or index < 1 or index > #pages then
        return nil
    end
    if cache[index] then
        return cache[index]
    end
    local credentials = SuwayomiSettings:load()
    local result = SuwayomiAPI.downloadBinary(credentials, pages[index], {
        total_timeout_seconds = PAGE_TIMEOUT_SECONDS,
    })
    if result and result.ok and type(result.body) == "string" then
        cache[index] = result.body
        self:trimStreamImageCache(cache, index)
        return result.body
    end
    return nil
end

function Methods:cancelStreamPrefetch()
    local state = self.stream_prefetch
    self.stream_prefetch = nil
    if not state then
        return false
    end
    -- A tick may be parked inside a blocking page fetch right now, where
    -- unscheduling cannot reach it, so it also checks this flag on the way out.
    state.cancelled = true
    if state.task then
        UIManager:unschedule(state.task)
    end
    return true
end

-- One page per scheduled tick. Fetching the whole prefetch window in a single
-- callback would hold the UI thread for several sequential HTTP requests.
function Methods:prefetchStreamPages(from_index)
    local session = self.stream_session
    if not session or not session.pages or not session.image_cache then
        return
    end

    self:cancelStreamPrefetch()
    from_index = from_index or 1
    local state = { offset = 0, cancelled = false }

    local function isCurrent()
        return not state.cancelled
            and self.stream_prefetch == state
            and self.stream_session == session
            and self.stream_viewer ~= nil
    end

    state.task = function()
        if not isCurrent() then
            return
        end

        state.offset = state.offset + 1
        local index = from_index + state.offset
        if state.offset > PREFETCH_AHEAD or index > #session.pages then
            if self.stream_prefetch == state then
                self.stream_prefetch = nil
            end
            return
        end

        if not session.image_cache[index] then
            self:downloadStreamPageBytes(session.pages, index, session.image_cache)
        end
        if not isCurrent() then
            return
        end
        UIManager:scheduleIn(PREFETCH_INTERVAL_SECONDS, state.task)
    end

    self.stream_prefetch = state
    UIManager:scheduleIn(PREFETCH_INTERVAL_SECONDS, state.task)
end

function Methods:prefetchNextChapterPages()
    local next_chapter = self:getAdjacentStreamChapter(1)
    if not next_chapter or not next_chapter.id then
        return
    end
    if self.stream_page_lists and self.stream_page_lists[chapterKey(next_chapter)] then
        return
    end
    local credentials = SuwayomiSettings:load()
    NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = {
            action = "fetch_chapter_pages",
            chapter_id = next_chapter.id,
        },
        result_prefix = "chapter_stream_prefetch",
        timeout_seconds = 90,
        on_finish = function(result)
            if result and result.ok then
                self:rememberStreamPageCache(next_chapter.id, result.pages)
            end
        end,
    })
end

function Methods:closeStreamViewer()
    self:cancelStreamPrefetch()
    local viewer = self.stream_viewer
    if viewer and viewer._images_list_cur then
        pcall(function()
            self:syncStreamPageProgress(viewer._images_list_cur)
        end)
    end
    self.stream_viewer = nil
    if viewer then
        UIManager:close(viewer)
    end
end

-- Page bodies are several megabytes each, so they are dropped once no viewer
-- can ask for them again.
function Methods:releaseStreamSession()
    self:cancelStreamPrefetch()
    self.stream_session = nil
end

function Methods:streamAdjacentChapter(delta)
    local next_chapter = self:getAdjacentStreamChapter(delta)
    local session = self.stream_session
    if not next_chapter then
        if delta > 0 then
            self:showMessage(I18n.t("No next chapter."))
        else
            self:showMessage(I18n.t("No previous chapter."))
        end
        return false
    end
    if delta > 0 and session and session.chapter and self.markChapterRead then
        session.advancing = true
        self:markChapterRead(session.manga, session.chapter, {
            last_page_read = session.pages and math.max(0, #session.pages - 1) or nil,
        })
    end
    local chapters = session.chapters
    if type(chapters) ~= "table" or #chapters == 0 then
        chapters = self:getStreamChapters(session.manga)
    end
    self:closeStreamViewer()
    return self:streamChapter(session.manga, next_chapter, { chapters = chapters })
end

function Methods:syncStreamPageProgress(page)
    local session = self.stream_session
    page = math.floor(tonumber(page) or 0)
    if not session or not session.chapter or page <= 0 then
        return false
    end
    local server_page = page - 1
    if server_page == session.last_synced_page then
        return false
    end
    session.last_synced_page = server_page

    -- Write to ledger so it survives a crash or close.
    if self.updateChapterProgress then
        self:updateChapterProgress(session.manga, session.chapter, server_page)
    end

    -- Also fire a direct API call immediately (after page image has been handed
    -- back to the viewer) so the server sees progress even if the queued sync
    -- worker never gets a chance to run while we are busy downloading images.
    local chapter_id = tostring(session.chapter.id or "")
    local synced_page = server_page
    UIManager:scheduleIn(0.5, function()
        pcall(function()
            local credentials = SuwayomiSettings:load()
            if credentials and credentials.server_url and credentials.server_url ~= "" then
                SuwayomiAPI.markChapterProgress(credentials, chapter_id, false, synced_page)
            end
        end)
    end)

    return true
end

function Methods:showStreamChapterPicker()
    local session = self.stream_session
    if not session then
        return
    end
    local chapters = self:getStreamChapters(session.manga)
    if type(chapters) ~= "table" or #chapters == 0 then
        self:showMessage(I18n.t("No chapters are available for this manga."))
        return
    end
    local current_index = self:getStreamChapterIndex(session.chapter, session.manga)
    local menu
    menu = SuwayomiUI.showChapterMenu({
        title = session.manga and session.manga.title or I18n.t("Chapters"),
        chapters = chapters,
        itemnumber = current_index,
    }, function(chapter)
        UIManager:close(menu)
        self:closeStreamViewer()
        self:streamChapter(session.manga, chapter, { chapters = chapters })
    end)
end

function Methods:showStreamReaderMenu()
    local session = self.stream_session
    if not session then
        return
    end
    local next_chapter = self:getAdjacentStreamChapter(1)
    local prev_chapter = self:getAdjacentStreamChapter(-1)
    local actions = {}
    if next_chapter then
        table.insert(actions, { id = "next", text = I18n.t("Next chapter") })
    end
    if prev_chapter then
        table.insert(actions, { id = "prev", text = I18n.t("Previous chapter") })
    end
    table.insert(actions, { id = "pick", text = I18n.t("Select chapter from this manga") })
    table.insert(actions, { id = "jump", text = I18n.t("Jump to page...") })
    local is_hidden = SuwayomiSettings:loadHideStreamTitleBar()
    table.insert(actions, { id = "toggle_bar", text = is_hidden and I18n.t("Show Top Bar") or I18n.t("Hide Top Bar (Edge-to-Edge)") })
    if self.showMangaTrackers then
        table.insert(actions, { id = "trackers", text = I18n.t("Trackers") })
    end
    local ok_manga, Manga = pcall(require, "desktop_modules/module_manga")
    if ok_manga and Manga and session.manga then
        local fp = session.manga.filepath or session.manga.title or tostring(session.manga.id or "")
        local pinned = Manga.isPinnedManga and Manga.isPinnedManga(fp)
        table.insert(actions, { id = "pin", text = pinned and I18n.t("Unpin from Home") or I18n.t("Pin to Home") })
    end
    SuwayomiUI.showActionMenu({
        title = session.chapter and session.chapter.name or I18n.t("Chapter"),
        actions = actions,
        vertical = true,
    }, function(action)
        if not action then
            return
        end
        if action.id == "next" then
            self:streamAdjacentChapter(1)
        elseif action.id == "prev" then
            self:streamAdjacentChapter(-1)
        elseif action.id == "pick" then
            self:showStreamChapterPicker()
        elseif action.id == "jump" then
            local InputDialog = require("ui/widget/inputdialog")
            local cur = self.stream_viewer and self.stream_viewer._images_list_cur or 1
            local total = session.pages and #session.pages or 1
            local dialog
            dialog = InputDialog:new{
                title = I18n.t("Jump to Page (1 - ") .. total .. ")",
                input = tostring(cur),
                input_type = "number",
                buttons = {
                    {
                        text = I18n.t("Cancel"),
                        id = "cancel",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = I18n.t("Go"),
                        is_default = true,
                        callback = function()
                            local page_num = tonumber(dialog:getInputText())
                            UIManager:close(dialog)
                            if page_num and page_num >= 1 and page_num <= total and self.stream_viewer then
                                self.stream_viewer:switchToImageNum(page_num)
                                self:syncStreamPageProgress(page_num)
                                self:prefetchStreamPages(page_num)
                            end
                        end,
                    },
                },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        elseif action.id == "toggle_bar" then
            local next_hide = not SuwayomiSettings:loadHideStreamTitleBar()
            SuwayomiSettings:saveHideStreamTitleBar(next_hide)
            self:showMessage(next_hide and I18n.t("Top Bar hidden (Edge-to-Edge)") or I18n.t("Top Bar visible"))
            local cur_session = self.stream_session
            local cur_page = self.stream_viewer and self.stream_viewer._images_list_cur or 1
            if cur_session and cur_session.manga and cur_session.chapter and cur_session.pages then
                self:showChapterStream(cur_session.manga, cur_session.chapter, cur_session.pages, cur_page, { chapters = cur_session.chapters })
            end
        elseif action.id == "pin" then
            local ok_m, Manga = pcall(require, "desktop_modules/module_manga")
            if session.manga then
                local fp = "suwayomi://manga/" .. tostring(session.manga.id or "")
                local is_pinned = ok_m and Manga and Manga.isPinnedManga and Manga.isPinnedManga(fp)
                if is_pinned then
                    if ok_m and Manga and Manga.removePinnedManga then Manga.removePinnedManga(fp) end
                    pcall(function()
                        local list = SuwayomiSettings:loadPinnedManga() or {}
                        local updated = {}
                        for _, m in ipairs(list) do
                            if tostring(m.id) ~= tostring(session.manga.id) then
                                table.insert(updated, m)
                            end
                        end
                        SuwayomiSettings:savePinnedManga(updated)
                    end)
                    self:showMessage(I18n.t("Unpinned from Home"))
                else
                    local cover_path
                    pcall(function()
                        local creds = SuwayomiSettings:load()
                        local tc = require("suwayomi/ui/thumbnail_cache")
                        local lfs = require("libs/libkoreader-lfs")
                        local url = session.manga.thumbnailUrl or session.manga.thumbnail_url
                        local variants = {
                            { variant = "manga_cover", width = 64, height = 96 },
                            { variant = "poster", width = 240, height = 360 },
                            { variant = "thumbnail", width = 64, height = 96 },
                            { variant = "poster", width = 160, height = 240 },
                            { variant = "poster", width = 320, height = 480 },
                            {},
                        }
                        for _, opts in ipairs(variants) do
                            local p = tc.find(creds, url, opts)
                            if p and lfs.attributes(p, "mode") == "file" then
                                cover_path = p
                                break
                            end
                        end
                    end)
                    if ok_m and Manga and Manga.addPinnedManga then
                        Manga.addPinnedManga(fp, session.manga.title or tostring(session.manga.id), cover_path)
                    end
                    pcall(function()
                        local list = SuwayomiSettings:loadPinnedManga() or {}
                        local found = false
                        for _, m in ipairs(list) do
                            if tostring(m.id) == tostring(session.manga.id) then found = true; break end
                        end
                        if not found then
                            table.insert(list, session.manga)
                            SuwayomiSettings:savePinnedManga(list)
                        end
                    end)
                    self:showMessage(I18n.t("Pinned to Home"))
                end
            end
        elseif action.id == "trackers" then
            self:showMangaTrackers(session.manga)
        end
    end)
end

function Methods:bindStreamViewerControls(viewer)
    local plugin = self
    local original_next = viewer.onShowNextImage
    local original_prev = viewer.onShowPrevImage
    local original_hold_release = viewer.onHoldRelease
    local original_swipe = viewer.onSwipe

    local function swipe_requests_next(direction)
        if direction == "west" or direction == "northwest" or direction == "southwest" then
            return not BD.mirroredUILayout()
        end
        if direction == "east" or direction == "northeast" or direction == "southeast" then
            return BD.mirroredUILayout()
        end
        return false
    end

    local function swipe_requests_prev(direction)
        if direction == "west" or direction == "northwest" or direction == "southwest" then
            return BD.mirroredUILayout()
        end
        if direction == "east" or direction == "northeast" or direction == "southeast" then
            return not BD.mirroredUILayout()
        end
        return false
    end

    -- ImageViewer only turns pages on tap; on e-ink most people swipe like in the
    -- normal reader, which otherwise just pans the zoomed image.
    function viewer:onSwipe(arg, ges)
        ges = ges or arg
        if self._images_list and (self.scale_factor or 0) == 0 and ges and ges.direction then
            if swipe_requests_next(ges.direction) then
                self:onShowNextImage()
                return true
            end
            if swipe_requests_prev(ges.direction) then
                self:onShowPrevImage()
                return true
            end
        end
        if original_swipe then
            return original_swipe(self, arg, ges)
        end
        return true
    end

    function viewer:onShowNextImage()
        if self._images_list_cur < self._images_list_nb then
            if original_next then
                original_next(self)
            else
                self:switchToImageNum(self._images_list_cur + 1)
            end
            plugin:syncStreamPageProgress(self._images_list_cur)
            plugin:prefetchStreamPages(self._images_list_cur)
            return
        end
        -- A forward turn after the final page marks this chapter complete and
        -- immediately replaces the viewer with the next chapter.
        plugin:streamAdjacentChapter(1)
    end

    function viewer:onShowPrevImage()
        if self._images_list_cur > 1 then
            if original_prev then
                original_prev(self)
            else
                self:switchToImageNum(self._images_list_cur - 1)
            end
            plugin:syncStreamPageProgress(self._images_list_cur)
            plugin:prefetchStreamPages(self._images_list_cur)
            return
        end
        plugin:streamAdjacentChapter(-1)
    end

    function viewer:onHoldRelease(arg, ges)
        ges = ges or arg
        if ges and ges.pos and self._panning then
            local dx = ges.pos.x - self._pan_relative_x
            local dy = ges.pos.y - self._pan_relative_y
            if math.abs(dx) < (self.pan_threshold or 10) and math.abs(dy) < (self.pan_threshold or 10) then
                self._panning = false
                plugin:showStreamReaderMenu()
                return true
            end
        end
        if original_hold_release then
            return original_hold_release(self, arg, ges)
        end
        return true
    end

    -- Long hold without moving opens the chapter menu on devices where the
    -- release handler above never sees _panning set.
    local original_hold = viewer.onHold
    function viewer:onHold(arg, ges)
        if original_hold then
            original_hold(self, arg, ges)
        else
            self._panning = true
            if ges and ges.pos then
                self._pan_relative_x = ges.pos.x
                self._pan_relative_y = ges.pos.y
            end
        end
        return true
    end
end

-- Page downloads are synchronous, so the screen would otherwise sit unchanged
-- for the length of the request and look like a freeze.
function Methods:withStreamLoadingFeedback(text, callback)
    local ok_widget, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not ok_widget or not InfoMessage then
        return callback()
    end

    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    if UIManager.forceRePaint then
        pcall(function()
            UIManager:forceRePaint()
        end)
    end
    local ok, result = pcall(callback)
    UIManager:close(info)
    if not ok then
        error(result)
    end
    return result
end

function Methods:showChapterStream(manga, chapter, pages, start_page, options)
    options = options or {}
    if type(pages) ~= "table" or #pages == 0 then
        self:showMessage(I18n.t("This chapter has no pages to stream."))
        return false
    end

    local chapters = options.chapters
    if type(chapters) ~= "table" or #chapters == 0 then
        chapters = self:getStreamChapters(manga)
    end
    self:rememberStreamChapterList(manga, chapters)

    -- Opening a chapter while another is on screen would stack two viewers.
    self:closeStreamViewer()

    self:rememberStreamPageCache(chapter and chapter.id, pages)
    local count = #pages
    local max_seen = start_page or 1
    local image_cache = {}
    local page_table = { image_disposable = true }
    local plugin = self

    -- Only the opening page is fetched up front; the rest arrive through
    -- prefetch once the viewer is on screen.
    self:withStreamLoadingFeedback(I18n.t("Loading page..."), function()
        self:downloadStreamPageBytes(pages, start_page or 1, image_cache)
    end)

    setmetatable(page_table, {
        __index = function(_, key)
            if type(key) ~= "number" then
                return renderPage(nil)
            end
            if key < 1 then
                key = 1
            end
            if key > count then
                key = count
            end
            max_seen = math.max(max_seen, key)
            pcall(function() plugin:syncStreamPageProgress(key) end)
            local bytes = plugin:downloadStreamPageBytes(pages, key, image_cache)
            plugin:prefetchStreamPages(key)
            return renderPage(bytes)
        end,
    })

    local ImageViewer = require("ui/widget/imageviewer")
    local title_str = chapter and chapter.name or I18n.t("Chapter")
    if manga and manga.title and manga.title ~= "" then
        title_str = manga.title .. " — " .. title_str
    end
    local hide_title = SuwayomiSettings:loadHideStreamTitleBar()
    local viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = not hide_title,
        title_text = title_str,
        image_disposable = false,
        images_list_nb = count,
    }

    -- ImageViewer does not call a widget-level close_callback, so closing is
    -- observed through its own close handler instead.
    local closed = false
    local function onViewerClosed()
        if closed then
            return
        end
        closed = true
        if self.stream_viewer == viewer then
            self.stream_viewer = nil
        end
        self:cancelStreamPrefetch()
        local session = self.stream_session
        if session and session.chapter == chapter then
            self:releaseStreamSession()
        end
        if max_seen >= count
            and chapter
            and self.markChapterRead
            and not (session and session.advancing)
        then
            self:markChapterRead(manga, chapter, {
                last_page_read = math.max(0, count - 1),
            })
        end
    end

    local original_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(viewer_self, ...)
        onViewerClosed()
        if original_close_widget then
            return original_close_widget(viewer_self, ...)
        end
    end

    self.stream_session = {
        manga = manga,
        chapter = chapter,
        chapters = chapters,
        pages = pages,
        image_cache = image_cache,
        last_synced_page = tonumber(chapter.last_page_read) or -1,
    }
    self.stream_viewer = viewer
    self:bindStreamViewerControls(viewer)
    UIManager:show(viewer)
    if start_page and start_page > 1 then
        viewer:switchToImageNum(math.min(start_page, count))
    end
    self:syncStreamPageProgress(start_page or 1)
    self:prefetchStreamPages(start_page or 1)
    self:prefetchNextChapterPages()
    return true
end

function Methods:streamChapter(manga, chapter, options)
    options = options or {}
    if not manga or not chapter or not chapter.id then
        self:showMessage(I18n.t("Could not stream this chapter."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    if not credentials.server_url or credentials.server_url == "" then
        self:showMessage(I18n.t("Set your Suwayomi server URL first."))
        return false
    end

    -- Waiting for Wi-Fi can outlive the plugin screen that asked for the stream.
    local generation = self:getStreamGeneration()
    local function isStreamStillWanted()
        return self:getStreamGeneration() == generation and not self.suwayomi_plugin_closing
    end

    local cached_pages = self.stream_page_lists and self.stream_page_lists[chapterKey(chapter)]
    local start_page = tonumber(options.start_page)
        or (tonumber(chapter.last_page_read) and tonumber(chapter.last_page_read) + 1)
        or 1
    if cached_pages then
        runWhenOnline(function()
            if not isStreamStillWanted() then
                return
            end
            self:showChapterStream(manga, chapter, cached_pages, start_page, options)
        end)
        return true
    end

    runWhenOnline(function()
        if not isStreamStillWanted() then
            return
        end
        self:cancelChapterStreamRequest()

        local request_token = {
            chapter_id = tostring(chapter.id),
        }
        self.active_chapter_stream_request = request_token

        local active = NetworkRequestJob.start({
            owner = self,
            credentials = credentials,
            request = {
                action = "fetch_chapter_pages",
                chapter_id = chapter.id,
            },
            loading_message = I18n.t("Loading pages..."),
            result_prefix = "chapter_stream",
            timeout_seconds = 90,
            timeout_message = I18n.t("Timed out while fetching chapter pages."),
            on_cancel = function()
                if self.active_chapter_stream_request == request_token then
                    self.active_chapter_stream_request = nil
                end
            end,
            on_finish = function(result)
                if self.active_chapter_stream_request ~= request_token then
                    return
                end
                self.active_chapter_stream_request = nil
                if not result or not result.ok then
                    self:showMessage((result and result.error) or I18n.t("Could not fetch chapter pages."))
                    return
                end
                self:showChapterStream(manga, chapter, result.pages, start_page, options)
            end,
        })

        if not active then
            if self.active_chapter_stream_request == request_token then
                self.active_chapter_stream_request = nil
            end
            self:showMessage(I18n.t("Could not start chapter stream."))
            return
        end
        request_token.active = active
    end)

    return true
end

Stream.methods = Methods

return Stream
