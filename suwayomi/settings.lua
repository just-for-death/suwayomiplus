-- Boundary: persisted plugin settings.
--
-- Responsibility: load, normalize, save, and flush Suwayomi plugin settings from
-- KOReader's settings directory.
-- Owned state: cached LuaSettings handle and settings file path.
-- Dependencies: datastorage and luasettings.
-- External data: stored settings tables are treated as optional and normalized
-- before callers consume them.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local SourceFilters = require("suwayomi/source_filters")

local SuwayomiSettings = {
    settings_file = DataStorage:getSettingsDir() .. "/suwayomi.lua",
    settings = nil,
}

local DEFAULT_CREDENTIALS = {
    server_url = "",
    username = "",
    password = "",
    auth_method = "basic_auth",
}
local SUPPORTED_AUTH_METHODS = {
    basic_auth = true,
}

local DEFAULT_SOURCE_LANGUAGES = { "en" }
local DEFAULT_BROWSE_SETTINGS = {
    show_nsfw_sources = false,
    hide_in_library_results = false,
}
local DEFAULT_LIBRARY_CATEGORY_PICKER_BEHAVIOR = "automatic"
local LIBRARY_CATEGORY_PICKER_BEHAVIORS = {
    automatic = true,
    always = true,
    never = true,
}
local DEFAULT_DOWNLOAD_DIRECTORY = ""
local DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS = 1
local MIN_PARALLEL_CHAPTER_DOWNLOADS = 1
local MAX_PARALLEL_CHAPTER_DOWNLOADS = 4
local DEFAULT_DELETE_CHAPTERS_SETTINGS = {
    delete_after_mark_read = false,
    delete_finished_while_reading = 0,
}
local DELETE_FINISHED_WHILE_READING_LIMITS = {
    [0] = true,
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
}
local DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS = 0
local MANGA_KEEP_NEXT_UNREAD_DOWNLOAD_LIMITS = {
    [0] = true,
    [5] = true,
    [10] = true,
    [50] = true,
}
local MAX_PINNED_MANGA = 50
local MAX_RECENT_MANGA = 20

local function copyTable(source)
    local target = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function toStringOrDefault(value, default)
    if value == nil then
        return default or ""
    end
    return tostring(value)
end

local function normalizeDownloadDirectory(value)
    if type(value) ~= "string" then
        return DEFAULT_DOWNLOAD_DIRECTORY
    end
    return value
end

local function rollingHash(text, seed, multiplier)
    local hash = seed
    multiplier = multiplier or 131
    for index = 1, #text do
        hash = (hash * multiplier + text:byte(index)) % 4294967296
    end
    return hash
end

local function hashText(text)
    return string.format(
        "%08x%08x",
        rollingHash(text, 2166136261, 131),
        rollingHash(text, 16777619, 65599)
    )
end

function SuwayomiSettings:normalizeCredentials(credentials)
    if type(credentials) ~= "table" then
        credentials = {}
    end
    local auth_method = toStringOrDefault(credentials.auth_method, DEFAULT_CREDENTIALS.auth_method)
    if not SUPPORTED_AUTH_METHODS[auth_method] then
        auth_method = DEFAULT_CREDENTIALS.auth_method
    end
    return {
        server_url = self:normalizeServerURL(toStringOrDefault(credentials.server_url, DEFAULT_CREDENTIALS.server_url)),
        username = toStringOrDefault(credentials.username, DEFAULT_CREDENTIALS.username),
        password = toStringOrDefault(credentials.password, DEFAULT_CREDENTIALS.password),
        auth_method = auth_method,
    }
end

function SuwayomiSettings:getAuthIdentity(credentials)
    if type(credentials) ~= "table" then
        return ""
    end
    local normalized = self:normalizeCredentials(credentials)
    return hashText(table.concat({
        normalized.auth_method,
        normalized.username,
        normalized.password,
    }, "\n"))
end

function SuwayomiSettings:getSourceCacheScope(credentials_or_url)
    if type(credentials_or_url) == "table" then
        local credentials = self:normalizeCredentials(credentials_or_url)
        return credentials.server_url, self:getAuthIdentity(credentials)
    end
    return tostring(credentials_or_url or ""), ""
end

function SuwayomiSettings:normalizeChapterLedgerEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local normalized = {
        manga_id = entry.manga_id ~= nil and tostring(entry.manga_id) or nil,
        manga_title = entry.manga_title ~= nil and tostring(entry.manga_title) or nil,
        chapter_id = entry.chapter_id ~= nil and tostring(entry.chapter_id) or nil,
        chapter_name = entry.chapter_name ~= nil and tostring(entry.chapter_name) or nil,
        path = entry.path ~= nil and tostring(entry.path) or nil,
        read = entry.read == true,
        pending_read_sync = entry.pending_read_sync == true or nil,
    }
    if entry.pending_read_state ~= nil then
        normalized.pending_read_state = entry.pending_read_state == true or entry.pending_read_state == 1
    end
    return normalized
end

function SuwayomiSettings:normalizeChapterLedger(ledger)
    if type(ledger) ~= "table" then
        return {}
    end
    local normalized = {}
    for key, entry in pairs(ledger) do
        local normalized_entry = self:normalizeChapterLedgerEntry(entry)
        if normalized_entry then
            normalized[tostring(key)] = normalized_entry
        end
    end
    return normalized
end

function SuwayomiSettings:normalizeMaxParallelChapterDownloads(value)
    local normalized = tonumber(value) or DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS
    normalized = math.floor(normalized)
    if normalized < MIN_PARALLEL_CHAPTER_DOWNLOADS then
        return MIN_PARALLEL_CHAPTER_DOWNLOADS
    end
    if normalized > MAX_PARALLEL_CHAPTER_DOWNLOADS then
        return MAX_PARALLEL_CHAPTER_DOWNLOADS
    end
    return normalized
end

function SuwayomiSettings:normalizeDeleteChaptersSettings(value)
    if type(value) ~= "table" then
        return copyTable(DEFAULT_DELETE_CHAPTERS_SETTINGS)
    end

    local delete_finished_while_reading = tonumber(value.delete_finished_while_reading)
        or DEFAULT_DELETE_CHAPTERS_SETTINGS.delete_finished_while_reading
    delete_finished_while_reading = math.floor(delete_finished_while_reading)
    if not DELETE_FINISHED_WHILE_READING_LIMITS[delete_finished_while_reading] then
        delete_finished_while_reading = DEFAULT_DELETE_CHAPTERS_SETTINGS.delete_finished_while_reading
    end

    return {
        delete_after_mark_read = value.delete_after_mark_read == true,
        delete_finished_while_reading = delete_finished_while_reading,
    }
end

function SuwayomiSettings:normalizeMangaKeepNextUnreadDownloads(value)
    local normalized = tonumber(value) or DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    normalized = math.floor(normalized)
    if MANGA_KEEP_NEXT_UNREAD_DOWNLOAD_LIMITS[normalized] then
        return normalized
    end
    return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
end

function SuwayomiSettings:getMangaSettingsKey(manga)
    if type(manga) ~= "table" then
        return nil
    end
    local key = manga.id or manga.title
    if key == nil or tostring(key) == "" then
        return nil
    end
    return tostring(key)
end

function SuwayomiSettings:getMangaKeepNextUnreadDownloadsKey(manga)
    return self:getMangaSettingsKey(manga)
end

function SuwayomiSettings:normalizeMangaScanlatorFilter(scanlator)
    if type(scanlator) ~= "string" and type(scanlator) ~= "number" then
        return nil
    end
    local normalized = tostring(scanlator)
    if normalized == "" then
        return nil
    end
    return normalized
end

function SuwayomiSettings:open()
    if not self.settings then
        self.settings = LuaSettings:open(self.settings_file)
    end
    return self.settings
end

function SuwayomiSettings:getSettingsDir()
    return DataStorage:getSettingsDir()
end

function SuwayomiSettings:normalizeServerURL(server_url)
    if not server_url or server_url == "" then
        return ""
    end

    if server_url:match("^%a+://") then
        return server_url
    end

    return "http://" .. server_url
end

function SuwayomiSettings:load()
    return self:normalizeCredentials(self:open():readSetting("credentials", copyTable(DEFAULT_CREDENTIALS)))
end

function SuwayomiSettings:save(credentials)
    credentials = self:normalizeCredentials(credentials)
    self:open():saveSetting("credentials", credentials):flush()
    return credentials
end

function SuwayomiSettings:loadSourceLanguages()
    return self:open():readSetting("source_languages", copyTable(DEFAULT_SOURCE_LANGUAGES))
end

function SuwayomiSettings:saveSourceLanguages(source_languages)
    local normalized = {}
    for _, lang in ipairs(source_languages or {}) do
        table.insert(normalized, lang)
    end

    self:open():saveSetting("source_languages", normalized):flush()
    return normalized
end

function SuwayomiSettings:normalizeBrowseSettings(browse_settings)
    browse_settings = type(browse_settings) == "table" and browse_settings or {}
    return {
        show_nsfw_sources = browse_settings.show_nsfw_sources == true,
        hide_in_library_results = browse_settings.hide_in_library_results == true,
    }
end

function SuwayomiSettings:loadBrowseSettings()
    return self:normalizeBrowseSettings(
        self:open():readSetting("browse_settings", copyTable(DEFAULT_BROWSE_SETTINGS))
    )
end

function SuwayomiSettings:saveBrowseSettings(browse_settings)
    local normalized = self:normalizeBrowseSettings(browse_settings)
    self:open():saveSetting("browse_settings", normalized):flush()
    return normalized
end

function SuwayomiSettings:normalizeLibraryCategoryPickerBehavior(behavior)
    if LIBRARY_CATEGORY_PICKER_BEHAVIORS[behavior] then
        return behavior
    end
    return DEFAULT_LIBRARY_CATEGORY_PICKER_BEHAVIOR
end

function SuwayomiSettings:loadLibraryCategoryPickerBehavior()
    return self:normalizeLibraryCategoryPickerBehavior(
        self:open():readSetting("library_category_picker_behavior", DEFAULT_LIBRARY_CATEGORY_PICKER_BEHAVIOR)
    )
end

function SuwayomiSettings:saveLibraryCategoryPickerBehavior(behavior)
    local normalized = self:normalizeLibraryCategoryPickerBehavior(behavior)
    self:open():saveSetting("library_category_picker_behavior", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadSourceCache(credentials_or_url)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    local cache = self:open():readSetting("source_cache", nil)
    if type(cache) ~= "table"
        or cache.server_url ~= server_url
        or tostring(cache.auth_identity or "") ~= auth_identity
    then
        return nil
    end
    cache.sources = type(cache.sources) == "table" and cache.sources or {}
    cache.updated_at = tonumber(cache.updated_at) or 0
    return cache
end

function SuwayomiSettings:saveSourceCache(credentials_or_url, sources, updated_at)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    local normalized = {
        server_url = server_url,
        auth_identity = auth_identity,
        sources = {},
        updated_at = tonumber(updated_at) or os.time(),
    }
    for _, source in ipairs(sources or {}) do
        table.insert(normalized.sources, source)
    end

    self:open():saveSetting("source_cache", normalized):flush()
    return normalized
end

local function emptySourceFilterDraft()
    return {
        query = "",
        filters = {},
    }
end

function SuwayomiSettings:loadSourceFilterDraft(credentials_or_url, source_id)
    local server_url, auth_identity = self:getSourceCacheScope(credentials_or_url)
    local drafts = self:open():readSetting("source_filter_drafts", nil)
    if type(drafts) ~= "table"
        or drafts.server_url ~= server_url
        or tostring(drafts.auth_identity or "") ~= auth_identity
        or type(drafts.sources) ~= "table"
    then
        return emptySourceFilterDraft()
    end

    local draft = drafts.sources[tostring(source_id or "")]
    if draft == nil then
        return emptySourceFilterDraft()
    end
    return SourceFilters.normalizeDraft(draft)
end

local function loadDraftStore(settings, credentials_or_url)
    local server_url, auth_identity = settings:getSourceCacheScope(credentials_or_url)
    local drafts = settings:open():readSetting("source_filter_drafts", nil)
    if type(drafts) ~= "table"
        or drafts.server_url ~= server_url
        or tostring(drafts.auth_identity or "") ~= auth_identity
        or type(drafts.sources) ~= "table"
    then
        drafts = {
            server_url = server_url,
            auth_identity = auth_identity,
            sources = {},
        }
    end
    return drafts
end

function SuwayomiSettings:saveSourceFilterDraft(credentials_or_url, source_id, draft)
    local source_key = tostring(source_id or "")
    local normalized = SourceFilters.normalizeDraft(draft)
    local drafts = loadDraftStore(self, credentials_or_url)
    drafts.sources[source_key] = normalized
    self:open():saveSetting("source_filter_drafts", drafts):flush()
    return normalized
end

function SuwayomiSettings:clearSourceFilterDraft(credentials_or_url, source_id)
    local source_key = tostring(source_id or "")
    local drafts = loadDraftStore(self, credentials_or_url)
    drafts.sources[source_key] = nil
    self:open():saveSetting("source_filter_drafts", drafts):flush()
    return emptySourceFilterDraft()
end

function SuwayomiSettings:getDefaultDownloadDirectory()
    local downloads_dir = "/mnt/us/Books/Manga"
    local ok_lfs, lfs = pcall(require, "suwayomi/fs")
    if ok_lfs and lfs then
        if lfs.attributes(downloads_dir, "mode") ~= "directory" then
            local parent = "/mnt/us/Books"
            if lfs.attributes(parent, "mode") ~= "directory" then
                pcall(lfs.mkdir, parent)
            end
            pcall(lfs.mkdir, downloads_dir)
        end
    end
    return downloads_dir
end

function SuwayomiSettings:loadDownloadDirectory()
    local dir = self:open():readSetting("download_directory", nil)
    if type(dir) == "string" and dir ~= "" then
        return dir
    end
    return self:getDefaultDownloadDirectory()
end

function SuwayomiSettings:saveDownloadDirectory(path)
    local normalized = normalizeDownloadDirectory(path)
    self:open():saveSetting("download_directory", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadDownloadQueue()
    local normalized, changed = self:normalizeDownloadQueue(self:open():readSetting("download_queue", {}))
    if changed then
        self:open():saveSetting("download_queue", normalized):flush()
    end
    return normalized
end

function SuwayomiSettings:normalizeDownloadQueue(jobs)
    local normalized = {}
    if type(jobs) ~= "table" then
        return normalized, jobs ~= nil
    end

    local changed = false
    local numeric_keys = {}
    for key in pairs(jobs) do
        if type(key) == "number" and key > 0 and math.floor(key) == key then
            table.insert(numeric_keys, key)
        else
            changed = true
        end
    end
    table.sort(numeric_keys)

    for index, key in ipairs(numeric_keys) do
        if key ~= index then
            changed = true
        end
        local job = jobs[key]
        if type(job) == "table" then
            table.insert(normalized, job)
        else
            changed = true
        end
    end

    return normalized, changed
end

function SuwayomiSettings:saveDownloadQueue(jobs)
    local normalized = self:normalizeDownloadQueue(jobs)
    self:open():saveSetting("download_queue", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadMaxParallelChapterDownloads()
    return self:normalizeMaxParallelChapterDownloads(
        self:open():readSetting("max_parallel_chapter_downloads", DEFAULT_MAX_PARALLEL_CHAPTER_DOWNLOADS)
    )
end

function SuwayomiSettings:saveMaxParallelChapterDownloads(value)
    local normalized = self:normalizeMaxParallelChapterDownloads(value)
    self:open():saveSetting("max_parallel_chapter_downloads", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadDeleteChaptersSettings()
    return self:normalizeDeleteChaptersSettings(
        self:open():readSetting("delete_chapters_settings", DEFAULT_DELETE_CHAPTERS_SETTINGS)
    )
end

function SuwayomiSettings:saveDeleteChaptersSettings(value)
    local normalized = self:normalizeDeleteChaptersSettings(value)
    self:open():saveSetting("delete_chapters_settings", normalized):flush()
    return normalized
end

function SuwayomiSettings:loadMangaKeepNextUnreadDownloads(manga)
    local key = self:getMangaKeepNextUnreadDownloadsKey(manga)
    if not key then
        return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    end
    local limits = self:open():readSetting("manga_keep_next_unread_downloads", {})
    if type(limits) ~= "table" then
        return DEFAULT_MANGA_KEEP_NEXT_UNREAD_DOWNLOADS
    end
    return self:normalizeMangaKeepNextUnreadDownloads(limits[key])
end

function SuwayomiSettings:saveMangaKeepNextUnreadDownloads(manga, limit)
    local key = self:getMangaKeepNextUnreadDownloadsKey(manga)
    local normalized = self:normalizeMangaKeepNextUnreadDownloads(limit)
    if not key then
        return normalized
    end

    local limits = self:open():readSetting("manga_keep_next_unread_downloads", {})
    if type(limits) ~= "table" then
        limits = {}
    end
    if normalized > 0 then
        limits[key] = normalized
    else
        limits[key] = nil
    end
    self:open():saveSetting("manga_keep_next_unread_downloads", limits):flush()
    return normalized
end

function SuwayomiSettings:loadMangaScanlatorFilter(manga)
    local key = self:getMangaSettingsKey(manga)
    if not key then
        return nil
    end
    local filters = self:open():readSetting("manga_scanlator_filters", {})
    if type(filters) ~= "table" then
        return nil
    end
    return self:normalizeMangaScanlatorFilter(filters[key])
end

function SuwayomiSettings:saveMangaScanlatorFilter(manga, scanlator)
    local key = self:getMangaSettingsKey(manga)
    local normalized = self:normalizeMangaScanlatorFilter(scanlator)
    if not key then
        return normalized
    end

    local filters = self:open():readSetting("manga_scanlator_filters", {})
    if type(filters) ~= "table" then
        filters = {}
    end
    if normalized then
        filters[key] = normalized
    else
        filters[key] = nil
    end
    self:open():saveSetting("manga_scanlator_filters", filters):flush()
    return normalized
end

function SuwayomiSettings:loadChapterLedger()
    return self:normalizeChapterLedger(self:open():readSetting("chapter_ledger", {}))
end

function SuwayomiSettings:saveChapterLedger(ledger)
    local normalized = self:normalizeChapterLedger(ledger)
    self:open():saveSetting("chapter_ledger", normalized):flush()
    return normalized
end

local DEFAULT_CHAPTER_CACHE_LIMIT_MB = 500
local CHAPTER_CACHE_LIMIT_CHOICES = {
    [100] = true,
    [250] = true,
    [500] = true,
    [1000] = true,
    [2000] = true,
}
local MAX_READER_CHAPTER_LIST_ENTRIES = 2000
local MAX_READER_CHAPTER_LISTS = 8
local DEFAULT_CHAPTER_TAP_ACTION = "quick_view"
local CHAPTER_TAP_ACTIONS = {
    quick_view = true,
    reader = true,
}

function SuwayomiSettings:normalizeChapterTapAction(value)
    if CHAPTER_TAP_ACTIONS[value] then
        return value
    end
    return DEFAULT_CHAPTER_TAP_ACTION
end

function SuwayomiSettings:loadChapterTapAction()
    return self:normalizeChapterTapAction(
        self:open():readSetting("chapter_tap_action", DEFAULT_CHAPTER_TAP_ACTION)
    )
end

function SuwayomiSettings:saveChapterTapAction(value)
    local normalized = self:normalizeChapterTapAction(value)
    self:open():saveSetting("chapter_tap_action", normalized):flush()
    return normalized
end

function SuwayomiSettings:normalizeChapterCacheLimitMB(value)
    local limit = math.floor(tonumber(value) or DEFAULT_CHAPTER_CACHE_LIMIT_MB)
    if not CHAPTER_CACHE_LIMIT_CHOICES[limit] then
        return DEFAULT_CHAPTER_CACHE_LIMIT_MB
    end
    return limit
end

function SuwayomiSettings:getChapterCacheLimitChoices()
    local choices = {}
    for limit in pairs(CHAPTER_CACHE_LIMIT_CHOICES) do
        table.insert(choices, limit)
    end
    table.sort(choices)
    return choices
end

function SuwayomiSettings:loadChapterCacheLimitMB()
    return self:normalizeChapterCacheLimitMB(
        self:open():readSetting("chapter_cache_limit_mb", DEFAULT_CHAPTER_CACHE_LIMIT_MB)
    )
end

function SuwayomiSettings:saveChapterCacheLimitMB(limit)
    local normalized = self:normalizeChapterCacheLimitMB(limit)
    self:open():saveSetting("chapter_cache_limit_mb", normalized):flush()
    return normalized
end

-- The reader runs its own plugin instance with no chapter menu state, so the
-- ordered chapter list is persisted whenever a chapter is opened.
function SuwayomiSettings:saveReaderChapterList(manga, chapters)
    local manga_id = manga and manga.id
    if manga_id == nil then
        return nil
    end

    local entries = {}
    for _, chapter in ipairs(chapters or {}) do
        if chapter and chapter.id ~= nil and #entries < MAX_READER_CHAPTER_LIST_ENTRIES then
            table.insert(entries, {
                id = tostring(chapter.id),
                name = chapter.name,
                is_read = chapter.is_read == true,
            })
        end
    end

    local list = {
        manga_id = tostring(manga_id),
        manga_title = manga.title,
        in_library = manga.in_library,
        chapters = entries,
        saved_at = os.time(),
    }

    -- Keyed by manga so reopening an older series from history still has its
    -- chapter order; oldest entries fall off once the cap is reached.
    local lists = self:open():readSetting("reader_chapter_lists", nil)
    if type(lists) ~= "table" then
        lists = {}
    end
    lists[list.manga_id] = list

    local keys = {}
    for key, entry in pairs(lists) do
        if type(entry) == "table" and type(entry.chapters) == "table" then
            table.insert(keys, key)
        else
            lists[key] = nil
        end
    end
    if #keys > MAX_READER_CHAPTER_LISTS then
        table.sort(keys, function(left, right)
            return (lists[left].saved_at or 0) > (lists[right].saved_at or 0)
        end)
        for index = MAX_READER_CHAPTER_LISTS + 1, #keys do
            lists[keys[index]] = nil
        end
    end

    self:open():saveSetting("reader_chapter_lists", lists):flush()
    return list
end

function SuwayomiSettings:loadReaderChapterList(manga_id)
    if manga_id == nil then
        return nil
    end

    local lists = self:open():readSetting("reader_chapter_lists", nil)
    local list = type(lists) == "table" and lists[tostring(manga_id)] or nil
    if type(list) ~= "table" or type(list.chapters) ~= "table" then
        -- Installs that predate the per-manga map still have one list saved.
        local legacy = self:open():readSetting("reader_chapter_list", nil)
        if type(legacy) == "table"
            and type(legacy.chapters) == "table"
            and tostring(legacy.manga_id or "") == tostring(manga_id)
        then
            return legacy
        end
        return nil
    end
    return list
end

function SuwayomiSettings:loadReaderReturnContexts()
    local contexts = self:open():readSetting("reader_return_contexts", {})
    if type(contexts) ~= "table" then
        return {}
    end
    return contexts
end

function SuwayomiSettings:saveReaderReturnContexts(contexts)
    if type(contexts) ~= "table" then
        contexts = {}
    end
    self:open():saveSetting("reader_return_contexts", contexts):flush()
    return contexts
end

local function normalizeSimpleUIManga(manga)
    if type(manga) ~= "table" or manga.id == nil then
        return nil
    end
    return {
        id = tostring(manga.id),
        title = manga.title ~= nil and tostring(manga.title) or tostring(manga.id),
        thumbnail_url = manga.thumbnail_url,
        in_library = manga.in_library == true,
        source = type(manga.source) == "table" and {
            id = manga.source.id,
            name = manga.source.name,
            displayName = manga.source.displayName or manga.source.display_name,
        } or nil,
    }
end

local function normalizeSimpleUIChapter(chapter)
    if type(chapter) ~= "table" or chapter.id == nil then
        return nil
    end
    return {
        id = tostring(chapter.id),
        name = chapter.name ~= nil and tostring(chapter.name) or tostring(chapter.id),
        is_read = chapter.is_read == true,
        last_page_read = tonumber(chapter.last_page_read),
        last_read_at = tonumber(chapter.last_read_at),
    }
end

function SuwayomiSettings:loadPinnedManga()
    local stored = self:open():readSetting("simpleui_pinned_manga", {})
    local pins = {}
    local seen = {}
    for _, manga in ipairs(type(stored) == "table" and stored or {}) do
        local normalized = normalizeSimpleUIManga(manga)
        if normalized and not seen[normalized.id] and #pins < MAX_PINNED_MANGA then
            seen[normalized.id] = true
            table.insert(pins, normalized)
        end
    end
    return pins
end

function SuwayomiSettings:savePinnedManga(manga_list)
    local pins = {}
    local seen = {}
    for _, manga in ipairs(type(manga_list) == "table" and manga_list or {}) do
        local normalized = normalizeSimpleUIManga(manga)
        if normalized and not seen[normalized.id] and #pins < MAX_PINNED_MANGA then
            seen[normalized.id] = true
            table.insert(pins, normalized)
        end
    end
    self:open():saveSetting("simpleui_pinned_manga", pins):flush()
    return pins
end

function SuwayomiSettings:loadRecentManga()
    local stored = self:open():readSetting("simpleui_recent_manga", {})
    local recents = {}
    local seen = {}
    for _, entry in ipairs(type(stored) == "table" and stored or {}) do
        local manga = normalizeSimpleUIManga(entry and entry.manga)
        local chapter = normalizeSimpleUIChapter(entry and entry.chapter)
        if manga and chapter and not seen[manga.id] and #recents < MAX_RECENT_MANGA then
            seen[manga.id] = true
            table.insert(recents, {
                manga = manga,
                chapter = chapter,
                updated_at = tonumber(entry.updated_at) or chapter.last_read_at or 0,
            })
        end
    end
    return recents
end

function SuwayomiSettings:saveRecentManga(entries)
    local recents = {}
    local seen = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local manga = normalizeSimpleUIManga(entry and entry.manga)
        local chapter = normalizeSimpleUIChapter(entry and entry.chapter)
        if manga and chapter and not seen[manga.id] and #recents < MAX_RECENT_MANGA then
            seen[manga.id] = true
            table.insert(recents, {
                manga = manga,
                chapter = chapter,
                updated_at = tonumber(entry.updated_at) or chapter.last_read_at or os.time(),
            })
        end
    end
    self:open():saveSetting("simpleui_recent_manga", recents):flush()
    return recents
end

return SuwayomiSettings
