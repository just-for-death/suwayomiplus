-- Boundary: auto-download on library add + tracked manga list.
--
-- Responsibility: queue missing/latest chapter downloads quietly for tracked
-- manga and for the global "on library add" policy.
-- Owned state: none; persistence lives in SuwayomiSettings.
-- Dependencies: chapter context, download queue, settings, i18n.

local I18n = require("suwayomi/i18n")
local SuwayomiDebug = require("suwayomi/debug")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")

local AutoDownload = {}
AutoDownload.__index = AutoDownload

function AutoDownload:new(deps)
    return setmetatable({ plugin = (deps or {}).plugin }, self)
end

local Methods = {}

local function modeLabel(mode)
    if mode == "latest" then
        return I18n.t("Latest")
    end
    if mode == "missing" then
        return I18n.t("Missing")
    end
    return I18n.t("Off")
end

function Methods:getAutoDownloadModeLabel(mode)
    return modeLabel(SuwayomiSettings:normalizeAutoDownloadMode(mode))
end

function Methods:getMissingChaptersForDownload(manga)
    local chapters = {}
    local max_count = self.max_batch_queue_chapters or 500
    for _, chapter in ipairs(self:getAllChaptersForManga(manga) or {}) do
        if not self:isChapterDownloaded(manga, chapter) then
            local status = self:getDownloadQueue():getStatus(manga, chapter)
            if not (status and (
                status.state == "queued"
                    or status.state == "downloading"
                    or status.state == "downloaded"
                    or status.state == "skipped"
            )) then
                table.insert(chapters, chapter)
                if #chapters >= max_count then
                    break
                end
            end
        end
    end
    return chapters
end

function Methods:resolveAutoDownloadModeForManga(manga, preferred_mode)
    if preferred_mode and preferred_mode ~= "off" then
        return SuwayomiSettings:normalizeAutoDownloadMode(preferred_mode)
    end
    local tracked = SuwayomiSettings:getAutoDownloadMangaEntry(manga)
    if tracked and tracked.mode then
        return tracked.mode
    end
    local on_add = SuwayomiSettings:loadAutoDownloadOnLibraryAdd()
    if on_add ~= "off" then
        return on_add
    end
    return "off"
end

function Methods:enqueueAutoDownloadForManga(manga, mode, options)
    options = options or {}
    local normalized = SuwayomiSettings:normalizeAutoDownloadMode(mode)
    if normalized == "off" or not manga or not manga.id then
        return false
    end

    local quiet = options.quiet == true
    local function queue(download_directory)
        local chapters
        if normalized == "latest" then
            local limit = SuwayomiSettings:loadAutoDownloadLatestLimit()
            chapters = self:getNextUnreadChaptersForDownload(manga, limit)
        else
            chapters = self:getMissingChaptersForDownload(manga)
        end

        if #(chapters or {}) == 0 then
            if not quiet then
                if normalized == "latest" then
                    self:showMessage(I18n.t("No unread chapters available to download."))
                else
                    self:showMessage(I18n.t("All chapters are already downloaded or queued."))
                end
            end
            return 0
        end

        return self:enqueueSelectedChapterDownloads(manga, chapters, download_directory, {
            quiet = quiet,
        })
    end

    local function queueAfterContext(download_directory)
        return self:withMangaChapterContext(manga, function()
            queue(download_directory)
        end, {
            sync_from_server = options.sync_from_server ~= false,
        })
    end

    local download_directory = self:getDownloadDirectoryOrChoose(function(path)
        queueAfterContext(path)
    end, {
        suppress_saved_message = quiet or nil,
    })
    if not download_directory then
        return true
    end
    return queueAfterContext(download_directory)
end

function Methods:maybeAutoDownloadAfterLibraryAdd(manga)
    if not manga or not manga.id then
        return false
    end
    local mode = self:resolveAutoDownloadModeForManga(manga)
    if mode == "off" then
        return false
    end
    -- Keep the title on the tracked list so MaxOutUI / later syncs use the same mode.
    SuwayomiSettings:upsertAutoDownloadManga(manga, mode)
    SuwayomiDebug.log({
        operation = "autoDownloadAfterLibraryAdd",
        manga_id = manga.id,
        mode = mode,
    })
    return self:enqueueAutoDownloadForManga(manga, mode, {
        quiet = true,
        sync_from_server = true,
    })
end

function Methods:addMangaToAutoDownload(manga, mode, options)
    options = options or {}
    local entry, err = SuwayomiSettings:upsertAutoDownloadManga(manga, mode or "missing")
    if not entry then
        if err == "limit" then
            self:showMessage(I18n.t("Auto-download list is full."))
        else
            self:showMessage(I18n.t("Could not add manga to auto-download."))
        end
        return false
    end
    if options.queue ~= false then
        self:enqueueAutoDownloadForManga(manga, entry.mode, {
            quiet = options.quiet == true,
            sync_from_server = true,
        })
    end
    if not options.quiet then
        self:showMessage(I18n.f(
            "Auto-download (%1): %2",
            modeLabel(entry.mode),
            entry.title or tostring(entry.id)
        ))
    end
    pcall(function()
        local Bridge = require("desktop_modules/suwayomi_bridge")
        if Bridge and Bridge.refreshHomescreenModule then
            Bridge.refreshHomescreenModule("suwayomi_auto_download")
        end
    end)
    return true
end

function Methods:removeMangaFromAutoDownload(manga, options)
    options = options or {}
    local removed = SuwayomiSettings:removeAutoDownloadManga(manga)
    if removed and not options.quiet then
        self:showMessage(I18n.t("Removed from auto-download."))
    end
    pcall(function()
        local Bridge = require("desktop_modules/suwayomi_bridge")
        if Bridge and Bridge.refreshHomescreenModule then
            Bridge.refreshHomescreenModule("suwayomi_auto_download")
        end
    end)
    return removed
end

function Methods:setAutoDownloadMangaMode(manga, mode, options)
    options = options or {}
    local entry = SuwayomiSettings:upsertAutoDownloadManga(manga, mode)
    if not entry then
        return false
    end
    if options.queue ~= false then
        self:enqueueAutoDownloadForManga(manga, entry.mode, {
            quiet = options.quiet == true,
            sync_from_server = true,
        })
    end
    pcall(function()
        local Bridge = require("desktop_modules/suwayomi_bridge")
        if Bridge and Bridge.refreshHomescreenModule then
            Bridge.refreshHomescreenModule("suwayomi_auto_download")
        end
    end)
    return true
end

function Methods:syncAllAutoDownloadManga(options)
    options = options or {}
    local list = SuwayomiSettings:loadAutoDownloadManga()
    if #list == 0 then
        if not options.quiet then
            self:showMessage(I18n.t("No manga in the auto-download list."))
        end
        return 0
    end
    for _, entry in ipairs(list) do
        self:enqueueAutoDownloadForManga(entry, entry.mode, {
            quiet = true,
            sync_from_server = true,
        })
    end
    if not options.quiet then
        self:showMessage(I18n.count(
            #list,
            "Queued auto-download for %1 manga.",
            "Queued auto-download for %1 manga."
        ))
    end
    return #list
end

function Methods:showAutoDownloadMangaManager(options)
    options = options or {}
    local list = SuwayomiSettings:loadAutoDownloadManga()
    local actions = {}
    for _, entry in ipairs(list) do
        table.insert(actions, {
            id = "manga:" .. entry.id,
            text = I18n.f("%1 (%2)", entry.title or entry.id, modeLabel(entry.mode)),
            entry = entry,
        })
    end
    table.insert(actions, { id = "sync_all", text = I18n.t("Download all now") })
    table.insert(actions, { id = "close", text = I18n.t("Close") })

    if #list == 0 then
        self:showMessage(I18n.t("Auto-download list is empty. Add manga from MaxOutUI or manga actions."))
        return false
    end

    return SuwayomiUI.showActionMenu({
        title = I18n.t("Auto-download manga"),
        actions = actions,
    }, function(action)
        if not action or action.id == "close" then
            return
        end
        if action.id == "sync_all" then
            self:syncAllAutoDownloadManga()
            return
        end
        local entry = action.entry
        if not entry then
            return
        end
        local cur_mode = entry.mode or "missing"
        SuwayomiUI.showActionMenu({
            title = entry.title or entry.id,
            actions = {
                { id = "download_missing", text = I18n.t("Download missing chapters") },
                { id = "download_now", text = I18n.f("Download now (%1)", modeLabel(cur_mode)) },
                { id = "mode_missing", text = cur_mode == "missing" and (I18n.t("Mode: Missing") .. " (Active)") or I18n.t("Mode: Missing") },
                { id = "mode_latest", text = cur_mode == "latest" and (I18n.t("Mode: Latest") .. " (Active)") or I18n.t("Mode: Latest") },
                { id = "trackers", text = I18n.t("Trackers") },
                { id = "open_chapters", text = I18n.t("Open chapters") },
                { id = "remove", text = I18n.t("Remove from auto-download"), destructive = true },
            },
        }, function(sub)
            if not sub then
                return
            end
            if sub.id == "download_missing" then
                self:enqueueAutoDownloadForManga(entry, "missing")
            elseif sub.id == "download_now" then
                self:enqueueAutoDownloadForManga(entry, entry.mode)
            elseif sub.id == "mode_missing" then
                self:setAutoDownloadMangaMode(entry, "missing")
            elseif sub.id == "mode_latest" then
                self:setAutoDownloadMangaMode(entry, "latest")
            elseif sub.id == "trackers" then
                if self.showMangaTrackers then
                    self:showMangaTrackers(entry)
                elseif self.performMangaAction then
                    self:performMangaAction(entry, "trackers")
                end
            elseif sub.id == "open_chapters" then
                if self.showChaptersForManga then
                    self:showChaptersForManga(entry)
                end
            elseif sub.id == "remove" then
                self:removeMangaFromAutoDownload(entry)
            end
            if options.refresh then
                options.refresh()
            end
        end)
    end)
end

AutoDownload.methods = Methods

return AutoDownload
