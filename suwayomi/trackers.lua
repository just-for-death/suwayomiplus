-- Boundary: Suwayomi tracker UI (MAL, AniList, and other logged-in trackers).
--
-- Responsibility: list server trackers, bind/unbind a manga, and push progress.
-- Owned state: none beyond in-flight NetworkRequestJob tokens on the plugin.
-- Dependencies: Suwayomi API/settings/UI, KOReader dialogs.
-- External data: tracker login state lives on the Suwayomi server.

local I18n = require("suwayomi/i18n")
local InputDialog = require("ui/widget/inputdialog")
local NetworkRequestJob = require("suwayomi/network/request_job")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")
local UIManager = require("ui/uimanager")

local Trackers = {}
Trackers.__index = Trackers

function Trackers:new(deps)
    deps = deps or {}
    return setmetatable({
        plugin = deps.plugin,
    }, self)
end

local Methods = {}

local function runWhenOnline(callback)
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(callback)
        return
    end
    callback()
end

local function recordForTracker(records, tracker_id)
    for _, record in ipairs(records or {}) do
        if tostring(record.tracker_id) == tostring(tracker_id) then
            return record
        end
    end
    return nil
end

function Methods:trackTrackerRequest(job)
    if not job then
        return nil
    end
    self.active_tracker_requests = self.active_tracker_requests or {}
    self.active_tracker_requests[job] = true
    return job
end

function Methods:forgetTrackerRequest(job)
    if job and self.active_tracker_requests then
        self.active_tracker_requests[job] = nil
    end
end

-- Tracker results open menus and show messages, so anything still in flight has
-- to be dropped when the plugin closes.
function Methods:cancelTrackerRequests()
    local jobs = self.active_tracker_requests
    self.active_tracker_requests = nil
    if not jobs then
        return 0
    end

    local cancelled = 0
    for job in pairs(jobs) do
        if NetworkRequestJob.cancel then
            pcall(NetworkRequestJob.cancel, job)
        end
        cancelled = cancelled + 1
    end
    return cancelled
end

function Methods:startTrackerRequest(request, options)
    options = options or {}
    local credentials = SuwayomiSettings:load()
    local job
    job = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = request,
        loading_message = options.loading_message,
        result_prefix = options.result_prefix or "tracker",
        timeout_seconds = options.timeout_seconds or 45,
        timeout_message = options.timeout_message or I18n.t("Tracker request timed out."),
        on_finish = function(result)
            self:forgetTrackerRequest(job)
            if options.on_finish then
                options.on_finish(result)
            end
        end,
        on_cancel = function()
            self:forgetTrackerRequest(job)
        end,
    })
    return self:trackTrackerRequest(job)
end

function Methods:syncMangaTrackProgress(manga)
    if not manga or not manga.id then
        return false
    end
    runWhenOnline(function()
        self:startTrackerRequest({
            action = "track_progress",
            manga_id = manga.id,
        }, {
            result_prefix = "track_progress",
            loading_message = nil,
            on_finish = function()
                -- Best-effort; read sync already happened locally.
            end,
        })
    end)
    return true
end

function Methods:bindMangaTracker(manga, tracker, remote)
    self:startTrackerRequest({
        action = "bind_track",
        manga_id = manga.id,
        tracker_id = tracker.id,
        remote_id = remote.remote_id,
    }, {
        loading_message = I18n.t("Binding tracker..."),
        result_prefix = "bind_track",
        on_finish = function(result)
            if not result or not result.ok then
                self:showMessage((result and result.error) or I18n.t("Could not bind tracker."))
                return
            end
            self:showMessage(I18n.f("Tracking on %1.", tracker.name))
            self:syncMangaTrackProgress(manga)
            self:showMangaTrackers(manga)
        end,
    })
end

function Methods:unbindMangaTracker(manga, record)
    self:startTrackerRequest({
        action = "unbind_track",
        record_id = record.id,
    }, {
        loading_message = I18n.t("Removing tracker..."),
        result_prefix = "unbind_track",
        on_finish = function(result)
            if not result or not result.ok then
                self:showMessage((result and result.error) or I18n.t("Could not unbind tracker."))
                return
            end
            self:showMessage(I18n.t("Tracker removed."))
            self:showMangaTrackers(manga)
        end,
    })
end

function Methods:showTrackerSearchResults(manga, tracker, results)
    if type(results) ~= "table" or #results == 0 then
        self:showMessage(I18n.t("No tracker matches for this title."))
        return
    end
    local actions = {}
    for _, item in ipairs(results) do
        local extra = item.publishing_status or ""
        if item.total_chapters and item.total_chapters > 0 then
            extra = extra ~= "" and (extra .. " · " .. tostring(item.total_chapters) .. " ch")
                or (tostring(item.total_chapters) .. " ch")
        end
        local text = item.title
        if extra ~= "" then
            text = text .. "\n" .. extra
        end
        table.insert(actions, {
            id = "bind",
            text = text,
            remote = item,
        })
    end
    SuwayomiUI.showActionMenu({
        title = I18n.f("Search %1", tracker.name),
        actions = actions,
        vertical = true,
    }, function(action)
        if action and action.remote then
            self:bindMangaTracker(manga, tracker, action.remote)
        end
    end)
end

function Methods:searchMangaOnTracker(manga, tracker, query)
    self:startTrackerRequest({
        action = "search_tracker",
        tracker_id = tracker.id,
        query = query,
    }, {
        loading_message = I18n.t("Searching tracker..."),
        result_prefix = "search_tracker",
        timeout_seconds = 60,
        on_finish = function(result)
            if not result or not result.ok then
                self:showMessage((result and result.error) or I18n.t("Tracker search failed."))
                return
            end
            self:showTrackerSearchResults(manga, tracker, result.results)
        end,
    })
end

function Methods:promptTrackerSearch(manga, tracker)
    local dialog
    dialog = InputDialog:new{
        title = I18n.f("Search %1", tracker.name),
        input = manga.title or "",
        buttons = {
            {
                {
                    text = I18n.t("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = I18n.t("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog.getInputText and dialog:getInputText()
                            or (dialog.getInputValue and dialog:getInputValue())
                            or ""
                        query = tostring(query or "")
                        UIManager:close(dialog)
                        if query ~= "" then
                            self:searchMangaOnTracker(manga, tracker, query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Methods:showTrackerDetails(manga, tracker, record)
    local actions = {}
    if record then
        local progress = tostring(record.last_chapter_read or 0)
        if record.total_chapters and record.total_chapters > 0 then
            progress = progress .. " / " .. tostring(record.total_chapters)
        end
        table.insert(actions, {
            id = "sync",
            text = I18n.f("Sync progress (%1)", progress),
        })
        table.insert(actions, {
            id = "unbind",
            text = I18n.t("Stop tracking"),
            destructive = true,
        })
    elseif tracker.is_logged_in and not tracker.is_token_expired then
        table.insert(actions, { id = "bind", text = I18n.t("Start tracking") })
    end
    SuwayomiUI.showActionMenu({
        title = tracker.name,
        actions = actions,
        vertical = true,
        destructive_actions_at_bottom = true,
        on_back = function()
            self:showMangaTrackers(manga)
        end,
    }, function(action)
        if not action then
            return
        end
        if action.id == "bind" then
            self:promptTrackerSearch(manga, tracker)
        elseif action.id == "sync" then
            self:syncMangaTrackProgress(manga)
            self:showMessage(I18n.t("Tracker progress queued."))
        elseif action.id == "unbind" then
            self:unbindMangaTracker(manga, record)
        end
    end)
end

function Methods:showMangaTrackersMenu(manga, trackers, records)
    local actions = {}
    local logged_in = 0
    for _, tracker in ipairs(trackers or {}) do
        local record = recordForTracker(records, tracker.id)
        local status
        if tracker.is_token_expired then
            status = I18n.t("token expired")
        elseif not tracker.is_logged_in then
            status = I18n.t("not logged in")
        elseif record then
            status = I18n.t("tracking")
            logged_in = logged_in + 1
        else
            status = I18n.t("off")
            logged_in = logged_in + 1
        end
        table.insert(actions, {
            id = "tracker",
            text = tracker.name .. "  ·  " .. status,
            tracker = tracker,
            record = record,
        })
    end
    if #actions == 0 then
        self:showMessage(I18n.t("No trackers on this Suwayomi server."))
        return
    end
    if logged_in == 0 then
        self:showMessage(I18n.t("Log into MAL, AniList, or other trackers in the Suwayomi web UI first."))
    end
    SuwayomiUI.showActionMenu({
        title = I18n.t("Trackers"),
        actions = actions,
        vertical = true,
    }, function(action)
        if action and action.tracker then
            if not action.tracker.is_logged_in or action.tracker.is_token_expired then
                self:showMessage(I18n.f("Log into %1 in Suwayomi first.", action.tracker.name))
                return
            end
            self:showTrackerDetails(manga, action.tracker, action.record)
        end
    end)
end

function Methods:showMangaTrackers(manga)
    if not manga or not manga.id then
        self:showMessage(I18n.t("This manga has no id."))
        return false
    end
    runWhenOnline(function()
        self:startTrackerRequest({
            action = "fetch_trackers",
        }, {
            loading_message = I18n.t("Loading trackers..."),
            result_prefix = "fetch_trackers",
            on_finish = function(trackers_result)
                if not trackers_result or not trackers_result.ok then
                    self:showMessage((trackers_result and trackers_result.error) or I18n.t("Could not load trackers."))
                    return
                end
                self:startTrackerRequest({
                    action = "fetch_manga_track_records",
                    manga_id = manga.id,
                }, {
                    loading_message = I18n.t("Loading tracking..."),
                    result_prefix = "fetch_track_records",
                    on_finish = function(records_result)
                        local records = records_result and records_result.ok and records_result.records or {}
                        self:showMangaTrackersMenu(manga, trackers_result.trackers, records)
                    end,
                })
            end,
        })
    end)
    return true
end

Trackers.methods = Methods

return Trackers
