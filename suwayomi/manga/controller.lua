-- Boundary: MangaController.
--
-- Responsibility: Owns manga-level actions, library add/remove, chapter refresh, and first-unread selection.
-- Owned state: Coordinates API/client calls but leaves chapter row/menu state to chapter modules.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin i18n facade are required at module load to match the original plugin runtime.
-- External data: callers must continue to treat API responses, settings values, worker files, and filesystem paths as untrusted until checked locally.

local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local SuwayomiDebug = require("suwayomi/debug")
local NetworkRequestJob = require("suwayomi/network/request_job")
local MangaActionMenu = require("suwayomi/manga/action_menu")
local I18n = require("suwayomi/i18n")

local MangaController = {}
MangaController.__index = MangaController

-- Controllers expose new(deps) for a consistent boundary; methods remain plugin-bound mixins so this refactor can move code without changing callback behavior.
function MangaController:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function getLoadedMangaChapterContext(owner, manga)
    if not owner or not owner.current_chapter_context or not manga then
        return nil
    end
    if owner.isCurrentChapterContextForManga and not owner:isCurrentChapterContextForManga(manga) then
        return nil
    end
    if not owner.isCurrentChapterContextForManga and owner.current_chapter_context.manga ~= manga then
        return nil
    end
    if #(owner.current_chapter_context.chapters or {}) == 0 then
        return nil
    end
    return owner.current_chapter_context
end

local function findReturnedChapterItemNumber(chapters, context)
    if type(chapters) ~= "table" or type(context) ~= "table" then
        return nil
    end

    local chapter_id = context.chapter_id
    if chapter_id ~= nil and chapter_id ~= "" then
        chapter_id = tostring(chapter_id)
        for index, chapter in ipairs(chapters) do
            if tostring(chapter and chapter.id) == chapter_id then
                return index
            end
        end
    end

    local chapter_name = context.chapter_name
    if chapter_name ~= nil and chapter_name ~= "" then
        chapter_name = tostring(chapter_name)
        for index, chapter in ipairs(chapters) do
            if tostring(chapter and chapter.name) == chapter_name then
                return index
            end
        end
    end

    return nil
end

local function copyOptions(options)
    local copied = {}
    for key, value in pairs(options or {}) do
        copied[key] = value
    end
    return copied
end

function Methods:attachSourceToManga(manga, source)
    return self:getClient():attachSourceToManga(manga, source)
end


function Methods:isMangaUninitialized(manga)
    return manga and manga.initialized == false
end


function Methods:applyMangaRefreshResult(manga, refreshed_manga)
    if type(manga) ~= "table" or type(refreshed_manga) ~= "table" then
        return manga
    end
    for key, value in pairs(refreshed_manga) do
        manga[key] = value
    end
    return manga
end


function Methods:refreshUninitializedMangaForChapters(manga)
    return nil, self:isMangaUninitialized(manga) == true
end

function Methods:startMangaNetworkRequest(manga, request, loading_message, on_finish, timeout_message, slot_key)
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be loaded right now."))
        return false
    end

    local credentials = SuwayomiSettings:load()
    local active_requests = self.active_manga_network_requests or {}
    self.active_manga_network_requests = active_requests
    slot_key = slot_key or tostring(request and request.action or "manga_request")

    local previous = active_requests[slot_key]
    if previous and previous.active then
        NetworkRequestJob.cancel(previous.active)
    end

    local request_token = {
        manga_id = tostring(manga.id),
    }
    active_requests[slot_key] = request_token

    local active = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = request,
        loading_message = loading_message,
        result_prefix = "manga_request",
        timeout_seconds = self.manga_network_timeout_seconds or 30,
        timeout_message = timeout_message or I18n.t("Could not load chapters."),
        on_cancel = function()
            if active_requests[slot_key] == request_token then
                active_requests[slot_key] = nil
            end
        end,
        on_finish = function(result)
            if active_requests[slot_key] ~= request_token then
                return
            end
            active_requests[slot_key] = nil
            if on_finish then
                on_finish(result)
            end
        end,
    })
    if not active then
        if active_requests[slot_key] == request_token then
            active_requests[slot_key] = nil
        end
        return false
    end
    if active_requests[slot_key] == request_token then
        request_token.active = active
    end
    return true
end

function Methods:cancelMangaNetworkRequests()
    local active_requests = self.active_manga_network_requests
    if type(active_requests) ~= "table" then
        return false
    end

    local canceled = false
    for slot_key, request_token in pairs(active_requests) do
        active_requests[slot_key] = nil
        if request_token and request_token.active then
            NetworkRequestJob.cancel(request_token.active)
            canceled = true
        end
    end
    return canceled
end

function Methods:handleRefreshMangaResult(manga, result, options)
    options = options or {}
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(result.error)
        return false
    end
    if type(result.chapters) ~= "table" then
        self:showMessage(I18n.t("Suwayomi server did not refresh manga."))
        return false
    end

    self:applyMangaRefreshResult(manga, result.manga)
    if options.onMangaUpdated then
        options.onMangaUpdated(manga)
    end
    return self:showChapterResultForManga(manga, {
        ok = true,
        manga = manga,
        chapters = result.chapters,
    }, options)
end

function Methods:handleChapterContextResult(manga, result, on_ready)
    if not result then
        return false
    end
    if not result.ok then
        self:showMessage(result.error)
        return false
    end
    if type(result.chapters) ~= "table" or #result.chapters == 0 then
        self:showMessage(I18n.t("This manga has no chapters."))
        return false
    end

    if result.manga then
        self:applyMangaRefreshResult(manga, result.manga)
    end
    local chapters = self:mergeChaptersWithReadLedger(manga, result.chapters)
    local context = self:setCurrentMangaChapterContext(manga, chapters)
    if on_ready then
        on_ready(context)
    end
    return true
end

function Methods:startLoadMangaChapterContext(manga, on_ready)
    local action = self:isMangaUninitialized(manga) and "refresh_manga" or "fetch_chapters_for_manga"
    local message = action == "refresh_manga"
        and I18n.t("Refreshing chapters...")
        or I18n.t("Loading chapters...")
    return self:startMangaNetworkRequest(manga, {
        action = action,
        manga_id = manga and manga.id,
    }, message, function(result)
        self:handleChapterContextResult(manga, result, on_ready)
    end, I18n.t("Could not load chapters."), "chapter_context")
end

function Methods:withMangaChapterContext(manga, on_ready, options)
    options = options or {}
    local context
    if options.defer_empty_context_warning then
        context = getLoadedMangaChapterContext(self, manga)
    else
        context = self:ensureMangaChapterContext(manga)
    end
    if context then
        if on_ready then
            on_ready(context)
        end
        return true
    end
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga has no chapters loaded."))
        return false
    end
    return self:startLoadMangaChapterContext(manga, on_ready)
end

function Methods:startRefreshMangaForChapters(manga, options)
    return self:startMangaNetworkRequest(manga, {
        action = "refresh_manga",
        manga_id = manga and manga.id,
    }, I18n.t("Refreshing chapters..."), function(result)
        self:handleRefreshMangaResult(manga, result, options)
    end, I18n.t("Could not load chapters."), "chapter_menu")
end

function Methods:startFetchChaptersForManga(manga, options)
    return self:startMangaNetworkRequest(manga, {
        action = "fetch_chapters_for_manga",
        manga_id = manga and manga.id,
    }, I18n.t("Loading chapters..."), function(result)
        self:showChapterResultForManga(manga, result, options)
    end, I18n.t("Could not load chapters."), "chapter_menu")
end

function Methods:showChapterResultForManga(manga, result, options)
    options = options or {}
    if not result then
        return
    end
    if not result.ok then
        self:showMessage(result.error)
        return
    end

    SuwayomiDebug.log({
        operation = "showChaptersForManga",
        event = "chapters_loaded",
        manga_id = manga and manga.id,
        chapter_count = #(result.chapters or {}),
    })
    if not result.chapters or #result.chapters == 0 then
        self:showMessage(I18n.t("This manga has no chapters."))
        return
    end

    local chapters = self:mergeChaptersWithReadLedger(manga, result.chapters)
    self:setCurrentMangaChapterContext(manga, chapters)

    local previous_chapter_menu = self.current_chapter_menu
    if previous_chapter_menu and self.isSuwayomiScreenActive and self:isSuwayomiScreenActive(previous_chapter_menu) and self.closeMenu then
        self:closeMenu(previous_chapter_menu)
    end

    local chapter_menu
    self.current_chapter_options = self:buildChapterMenuOptions(manga, chapters)
    self.current_chapter_options.itemnumber = findReturnedChapterItemNumber(chapters, options.return_context)
    self.current_chapter_options.close_callback = function()
        local is_current_menu = self.current_chapter_menu == chapter_menu
        if is_current_menu then
            self.current_chapter_menu = nil
        end
        return nil
    end
    chapter_menu = SuwayomiUI.showChapterMenu(self.current_chapter_options, function(chapter)
        self:handleChapterTap(manga, chapter)
    end, function(chapter)
        self:handleChapterHold(manga, chapter)
    end)
    self.current_chapter_menu = chapter_menu
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("chapters", chapter_menu)
    end
    return true
end


function Methods:showChaptersForManga(manga)
    return SuwayomiDebug.time("showChaptersForManga", {
        manga_id = manga and manga.id,
    }, function()
        if self:isMangaUninitialized(manga) then
            return self:startRefreshMangaForChapters(manga)
        end
        return self:startFetchChaptersForManga(manga)
    end)
end


function Methods:canOpenFirstUnreadMangaChapter(manga)
    return MangaActionMenu.canOpenFirstUnread(self, manga)
end


function Methods:getMangaActions(manga)
    return MangaActionMenu.buildMainActions(self, manga, {
        include_open_chapters = true,
    })
end


function Methods:getMangaInformationActions(manga)
    local actions = {
        { id = "open_chapters", text = I18n.t("Open chapters") },
    }
    if MangaActionMenu.canOpenFirstUnread(self, manga) then
        table.insert(actions, { id = "open_first_unread", text = I18n.t("Open next unread") })
    end
    if manga and manga.id then
        if manga.in_library == true then
            table.insert(actions, { id = "remove_from_library", text = I18n.t("Remove from library"), destructive = true })
        else
            table.insert(actions, { id = "add_to_library", text = I18n.t("Add to library") })
        end
    end
    table.insert(actions, { id = "trackers", text = I18n.t("Trackers") })
    return actions
end


function Methods:showMangaActions(manga, options)
    options = options or {}
    local action_options = copyOptions(options)
    action_options.refresh_action_menu_after_library_update = true

    if SuwayomiUI.showMangaInformation then
        return self:performMangaAction(manga, "manga_information", action_options)
    end

    if not SuwayomiUI.showMangaActionsMenu then
        return self:showChaptersForManga(manga)
    end

    local menu = SuwayomiUI.showMangaActionsMenu({
        title = manga and (manga.title or tostring(manga.id)) or I18n.t("Manga actions"),
        actions = self:getMangaActions(manga),
    }, function(action)
        if action then
            self:performMangaAction(manga, action.id, action_options)
        end
    end)
    if self.trackSuwayomiScreen then
        self:trackSuwayomiScreen("manga-actions", menu)
    end
    return menu
end


function Methods:updateMangaFromLibraryStateResponse(manga, updated_manga, in_library)
    if type(manga) ~= "table" then
        return
    end
    manga.in_library = in_library == true
    if type(updated_manga) == "table" then
        for key, value in pairs(updated_manga) do
            manga[key] = value
        end
        manga.in_library = updated_manga.in_library
        if manga.in_library == nil then
            manga.in_library = in_library == true
        end
    end
end


function Methods:setMangaLibraryState(manga, in_library, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be updated right now."))
        return false
    end

    local loading_message = in_library
        and I18n.t("Adding to library...")
        or I18n.t("Removing from library...")
    local result
    result = self:startMangaNetworkRequest(manga, {
        action = "update_manga_library_state",
        manga_id = manga and manga.id,
        in_library = in_library == true,
    }, loading_message, function(response)
        if not response then
            return
        end
        if not response.ok then
            self:showMessage(response.error)
            return
        end

        self:updateMangaFromLibraryStateResponse(manga, response.manga, in_library)
        if options.onMangaUpdated then
            options.onMangaUpdated(manga)
        end
        if options.refresh_action_menu_after_library_update then
            self:showMangaActions(manga, options)
        end
    end, I18n.t("Could not update library."), "library_state:" .. tostring(manga.id))
    if not result then
        return false
    end
    return true
end


function Methods:addMangaToLibrary(manga, options)
    return self:setMangaLibraryState(manga, true, options)
end


function Methods:confirmRemoveMangaFromLibrary(manga, options)
    options = options or {}
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be updated right now."))
        return false
    end

    local callback = function()
        self:setMangaLibraryState(manga, false, options)
    end
    if SuwayomiUI.showConfirm then
        SuwayomiUI.showConfirm({
            text = I18n.f("Remove %1 from your Suwayomi library?", manga.title or tostring(manga.id)),
            ok_text = I18n.t("Remove"),
            ok_callback = callback,
            cancel_text = I18n.t("Cancel"),
        })
    else
        callback()
    end
    return true
end


function Methods:refreshMangaChapters(manga, options)
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga cannot be refreshed right now."))
        return false
    end

    return self:startRefreshMangaForChapters(manga, options)
end


function Methods:performMangaAction(manga, action_id, options)
    options = options or {}
    if action_id == "open_chapters" then
        self:showChaptersForManga(manga)
        return true
    end
    if action_id == "manga_information" then
        if SuwayomiUI.showMangaInformation then
            local info_action_options = copyOptions(options)
            info_action_options.refresh_action_menu_after_library_update = true
            local dialog = SuwayomiUI.showMangaInformation(manga, {
                actions = self:getMangaInformationActions(manga),
                onAction = function(action)
                    if action and action.id then
                        self:performMangaAction(manga, action.id, info_action_options)
                    end
                end,
            })
            if dialog and self.trackSuwayomiScreen then
                self:trackSuwayomiScreen("manga-information", dialog)
            end
            return true
        end
        return false
    end
    if action_id == "open_first_unread" then
        -- The action is offered from cached hints, so the filtered chapter list
        -- can still turn out to have nothing unread left.
        local function openFirstUnread()
            local chapter = self:getFirstUnreadChapterForManga(manga)
            if chapter then
                return self:openChapter(manga, chapter)
            end
            self:showMessage(I18n.t("No unread chapter to open."))
            return false
        end

        if getLoadedMangaChapterContext(self, manga) then
            return openFirstUnread()
        end
        return self:withMangaChapterContext(manga, openFirstUnread, {
            defer_empty_context_warning = true,
        })
    end
    if action_id == "refresh_chapters" then
        return self:refreshMangaChapters(manga, options)
    end
    if action_id == "add_to_library" then
        return self:addMangaToLibrary(manga, options)
    end
    if action_id == "remove_from_library" then
        return self:confirmRemoveMangaFromLibrary(manga, options)
    end
    if action_id == "trackers" then
        if self.showMangaTrackers then
            return self:showMangaTrackers(manga)
        end
        return false
    end
    return false
end


MangaController.methods = Methods

return MangaController
