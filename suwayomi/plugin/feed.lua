-- Boundary: Suwayomi History and library Updates feeds.

local I18n = require("suwayomi/i18n")
local NetworkRequestJob = require("suwayomi/network/request_job")
local SuwayomiSettings = require("suwayomi/settings")
local SuwayomiUI = require("suwayomi/ui")

local FeedController = {}
FeedController.__index = FeedController

function FeedController:new(deps)
    return setmetatable({ plugin = (deps or {}).plugin }, self)
end

local Methods = {}

local function findChapter(chapters, chapter_id)
    for _, chapter in ipairs(chapters or {}) do
        if tostring(chapter.id or "") == tostring(chapter_id or "") then
            return chapter
        end
    end
    return nil
end

function Methods:cancelFeedRequest()
    local request = self.active_feed_request
    self.active_feed_request = nil
    if request and request.job and NetworkRequestJob.cancel then
        NetworkRequestJob.cancel(request.job)
        return true
    end
    return false
end

function Methods:openFeedEntry(entry)
    if type(entry) ~= "table" or not entry.manga or not entry.chapter then
        return false
    end
    return self:withMangaChapterContext(entry.manga, function(context)
        local chapters = self:getVisibleChapters(context.chapters or {})
        local chapter = findChapter(chapters, entry.chapter.id) or entry.chapter
        self:streamChapter(entry.manga, chapter, { chapters = chapters })
    end, {
        defer_empty_context_warning = true,
    })
end

function Methods:showChapterFeed(kind)
    local credentials = SuwayomiSettings:load()
    if credentials.server_url == "" then
        self:showMessage(I18n.t("Set up your Suwayomi server login first."))
        return false
    end
    local is_history = kind == "history"
    local title = is_history and I18n.t("Reading History") or I18n.t("Library Updates")
    self:cancelFeedRequest()
    local token = { kind = kind }
    self.active_feed_request = token
    token.job = NetworkRequestJob.start({
        owner = self,
        credentials = credentials,
        request = {
            action = is_history and "fetch_history" or "fetch_updates",
            first = 100,
        },
        loading_message = is_history and I18n.t("Loading history...") or I18n.t("Loading updates..."),
        result_prefix = "chapter_feed",
        timeout_seconds = 60,
        on_finish = function(result)
            if self.active_feed_request ~= token then
                return
            end
            self.active_feed_request = nil
            if not result or not result.ok then
                self:showMessage((result and result.error) or I18n.t("Could not load chapter feed."))
                return
            end
            if #(result.entries or {}) == 0 then
                self:showMessage(is_history and I18n.t("No reading history yet.") or I18n.t("No library updates."))
                return
            end
            local ok, menu = pcall(SuwayomiUI.showFeedMenu, {
                    title = title,
                    kind = kind,
                    entries = result.entries,
                    thumbnail_credentials = credentials,
                }, function(entry)
                    self:openFeedEntry(entry)
                end)
            if not ok or not menu then
                self:showMessage(I18n.t("Could not open this feed."))
                return
            end
            if self.trackSuwayomiScreen then
                self:trackSuwayomiScreen(kind, menu)
            end
        end,
        on_cancel = function()
            if self.active_feed_request == token then
                self.active_feed_request = nil
            end
        end,
    })
    if not token.job and self.active_feed_request == token then
        self.active_feed_request = nil
    end
    return nil
end

function Methods:showHistory()
    return self:showChapterFeed("history")
end

function Methods:showUpdates()
    return self:showChapterFeed("updates")
end

FeedController.methods = Methods
return FeedController
