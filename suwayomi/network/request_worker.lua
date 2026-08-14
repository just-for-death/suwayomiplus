-- Boundary: generic Suwayomi network request worker process.
--
-- Responsibility: run selected API facade calls in a subprocess and persist a
-- compact result file for the UI process.
-- Owned state: none.
-- Dependencies: dkjson, Suwayomi API facade, and shared subprocess result IO.
-- External data: request tables and API results are normalized before writing.

local json = require("dkjson")
local SuwayomiAPI = require("suwayomi/api")
local SubprocessJob = require("suwayomi/subprocess/job")

local RequestWorker = {}
local LIBRARY_TOO_LARGE_ERROR = "Suwayomi library is too large to load at once."

local function libraryResultExceedsLimit(manga, total_count)
    local limit = tonumber(SubprocessJob.max_result_bytes)
    if not limit or limit <= 0 then
        return false
    end
    local encoded = json.encode({
        ok = true,
        manga = manga,
        total_count = total_count,
    })
    return type(encoded) == "string" and #encoded > limit
end

local function fetchLibraryMangaPages(credentials)
    local page_size = 100
    local offset = 0
    local all_manga = {}
    local server_total

    while true do
        local result = SuwayomiAPI.fetchLibraryManga(credentials, {
            first = page_size,
            offset = offset,
        })
        if not result.ok then
            return result
        end

        local page_manga = result.manga or {}
        for _, manga in ipairs(page_manga) do
            table.insert(all_manga, manga)
        end
        server_total = tonumber(result.total_count) or server_total

        if libraryResultExceedsLimit(all_manga, server_total or #all_manga) then
            return {
                ok = false,
                error = LIBRARY_TOO_LARGE_ERROR,
            }
        end

        -- Titles the parser had to skip still occupy a slot on the server page,
        -- so paging is driven by what the server sent.
        local page_node_count = tonumber(result.node_count) or #page_manga
        if page_node_count == 0 or page_node_count < page_size then
            break
        end
        -- Without a server total, a full page is not evidence of the end; keep
        -- walking until a short page arrives.
        if server_total and offset + page_node_count >= server_total then
            break
        end
        offset = offset + page_size
    end

    return {
        ok = true,
        manga = all_manga,
        total_count = server_total or #all_manga,
    }
end

local function fetchReaderReturnChapters(credentials, manga_id)
    local result = SuwayomiAPI.fetchChaptersForManga(credentials, manga_id)
    if not result.ok then
        return result
    end

    if SuwayomiAPI.fetchMangaById then
        local manga_result = SuwayomiAPI.fetchMangaById(credentials, manga_id)
        if manga_result and manga_result.ok and type(manga_result.manga) == "table" then
            result.manga = manga_result.manga
        end
    end
    return result
end

local function normalizeResult(result)
    if type(result) ~= "table" then
        return {
            ok = false,
            error = "Could not complete network request.",
        }
    end
    result.ok = result.ok == true
    if not result.ok then
        result.error = result.error or "Could not complete network request."
    end
    return result
end

function RequestWorker:writeResult(result_path, result)
    return SubprocessJob.writeResult(result_path, normalizeResult(result))
end

function RequestWorker:readResult(result_path)
    return normalizeResult(SubprocessJob.readResult(result_path, normalizeResult))
end

function RequestWorker:run(credentials, request, result_path)
    request = request or {}
    local ok, result = pcall(function()
        if request.action == "fetch_chapters_for_manga" then
            return SuwayomiAPI.fetchChaptersForManga(credentials, request.manga_id)
        end
        if request.action == "fetch_reader_return_chapters_for_manga" then
            return fetchReaderReturnChapters(credentials, request.manga_id)
        end
        if request.action == "refresh_manga" then
            return SuwayomiAPI.refreshManga(credentials, request.manga_id)
        end
        if request.action == "update_manga_library_state" then
            return SuwayomiAPI.updateMangaLibraryState(credentials, request.manga_id, request.in_library == true)
        end
        if request.action == "fetch_library_categories" then
            return SuwayomiAPI.fetchCategories(credentials)
        end
        if request.action == "fetch_library_manga_pages" then
            return fetchLibraryMangaPages(credentials)
        end
        if request.action == "fetch_chapter_pages" then
            return SuwayomiAPI.fetchChapterPages(credentials, request.chapter_id)
        end
        if request.action == "fetch_history" then
            return SuwayomiAPI.fetchHistory(credentials, request.first)
        end
        if request.action == "fetch_updates" then
            return SuwayomiAPI.fetchUpdates(credentials, request.first)
        end
        if request.action == "fetch_trackers" then
            return SuwayomiAPI.fetchTrackers(credentials)
        end
        if request.action == "fetch_manga_track_records" then
            return SuwayomiAPI.fetchMangaTrackRecords(credentials, request.manga_id)
        end
        if request.action == "search_tracker" then
            return SuwayomiAPI.searchTracker(credentials, request.tracker_id, request.query)
        end
        if request.action == "bind_track" then
            return SuwayomiAPI.bindTrack(credentials, request.manga_id, request.tracker_id, request.remote_id)
        end
        if request.action == "unbind_track" then
            return SuwayomiAPI.unbindTrack(credentials, request.record_id)
        end
        if request.action == "track_progress" then
            return SuwayomiAPI.trackProgress(credentials, request.manga_id)
        end
        return {
            ok = false,
            error = "Unsupported network request.",
        }
    end)

    if not ok then
        result = {
            ok = false,
            error = tostring(result),
        }
    end
    self:writeResult(result_path, result)
    return result
end

return RequestWorker
