-- Boundary: ContinueReadingController.
--
-- Responsibility: Find and open the next unread chapter for the user by
-- inspecting recent reading history and resuming at the first manga that
-- still has unread chapters.
-- Owned state: active NetworkRequestJob token only.
-- Dependencies: KOReader UI helpers, Suwayomi runtime modules, and the plugin
-- i18n facade.

local I18n = require("suwayomi/i18n")
local NetworkRequestJob = require("suwayomi/network/request_job")
local SuwayomiSettings = require("suwayomi/settings")

local ContinueReadingController = {}
ContinueReadingController.__index = ContinueReadingController

function ContinueReadingController:new(deps)
    return setmetatable({ plugin = (deps or {}).plugin }, self)
end

local Methods = {}

function Methods:cancelContinueReadingRequest()
    local request = self.active_continue_reading_request
    self.active_continue_reading_request = nil
    if request and request.job and NetworkRequestJob.cancel then
        NetworkRequestJob.cancel(request.job)
        return true
    end
    return false
end

function Methods:continueReading()
    local credentials = SuwayomiSettings:load()
    if credentials.server_url == "" then
        self:showMessage(I18n.t("Set up your Suwayomi server login first."))
        return false
    end

    self:cancelContinueReadingRequest()

    local token = {}
    self.active_continue_reading_request = token
    token.job = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = {
            action = "fetch_history",
            first = 10,
        },
        loading_message = I18n.t("Finding where you left off..."),
        result_prefix = "continue_reading",
        timeout_seconds = 30,
        on_finish = function(result)
            if self.active_continue_reading_request ~= token then
                return
            end
            self.active_continue_reading_request = nil

            if not result or not result.ok then
                self:showMessage(
                    (result and result.error) or I18n.t("Could not load reading history.")
                )
                return
            end

            local target_manga
            for _, entry in ipairs(type(result.entries) == "table" and result.entries or {}) do
                local manga = entry.manga
                if manga then
                    local has_unread = manga.first_unread_chapter ~= nil
                        or (type(manga.unread_count) == "number" and manga.unread_count > 0)
                    if has_unread then
                        target_manga = manga
                        break
                    end
                end
            end

            if not target_manga then
                self:showMessage(I18n.t("You're all caught up!"))
                return
            end

            self:resumeMangaStream(target_manga)
        end,
        on_cancel = function()
            if self.active_continue_reading_request == token then
                self.active_continue_reading_request = nil
            end
        end,
    })

    if not token.job and self.active_continue_reading_request == token then
        self.active_continue_reading_request = nil
    end
    return nil
end

ContinueReadingController.methods = Methods
return ContinueReadingController
