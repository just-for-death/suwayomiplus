-- Boundary: pure Suwayomi GraphQL request builders.
--
-- Responsibility: build JSON-encoded GraphQL queries and mutations without
-- knowing how they are transported or parsed.
-- Owned state: none.
-- Dependencies: dkjson only.
-- External data: caller-provided IDs, pagination, and filter values are coerced
-- into GraphQL-safe request bodies before leaving the plugin.

local Queries = {}
local json = require("dkjson")

local function normalizeNumber(value, fallback)
    local number = tonumber(value)
    if number then
        return number
    end
    return fallback
end

local LEGACY_MANGA_FIELDS = "id title inLibrary initialized thumbnailUrl"
local LEGACY_REFRESH_MANGA_FIELDS = "id title initialized thumbnailUrl"
local MANGA_FIELDS = "id title author artist description genre status inLibrary initialized thumbnailUrl"
local SAVED_SEARCHES_META_KEY = "webUI_savedSearches"
local SOURCE_FILTER_FIELDS = table.concat({
    "__typename",
    "... on HeaderFilter { name }",
    "... on SeparatorFilter { name }",
    "... on SelectFilter { name values selectDefault: default }",
    "... on TextFilter { name textDefault: default }",
    "... on CheckBoxFilter { name checkBoxDefault: default }",
    "... on TriStateFilter { name triStateDefault: default }",
    "... on SortFilter { name values sortDefault: default { index ascending } }",
}, " ")
local GROUP_FILTER_FIELDS_DEPTH_1 = SOURCE_FILTER_FIELDS
    .. " ... on GroupFilter { name filters { "
    .. SOURCE_FILTER_FIELDS
    .. " } }"
local GROUP_FILTER_FIELDS = SOURCE_FILTER_FIELDS
    .. " ... on GroupFilter { name filters { "
    .. GROUP_FILTER_FIELDS_DEPTH_1
    .. " } }"

function Queries._buildSourcesQuery()
    return json.encode({
        query = "query getSources { sources { nodes { id name displayName lang iconUrl isNsfw supportsLatest } } }",
    })
end

function Queries._buildConnectionTestQuery()
    return json.encode({
        query = "query { __typename }",
    })
end

function Queries._buildLegacySourcesQuery()
    return json.encode({
        query = "query getSources { sources { nodes { id name displayName lang } } }",
    })
end

function Queries._buildSourceFiltersQuery(source_id)
    local encoded_source_id = json.encode(tostring(source_id or ""))
    return json.encode({
        query = "query GET_SOURCE_FILTERS { source(id: "
            .. encoded_source_id
            .. ") { id displayName name filters { "
            .. GROUP_FILTER_FIELDS
            .. " } } }",
    })
end

function Queries._buildSourceMetadataQuery(source_id)
    local encoded_source_id = json.encode(tostring(source_id or ""))
    return json.encode({
        query = "query GET_SOURCE_METADATA { source(id: "
            .. encoded_source_id
            .. ") { id meta { key value } } }",
    })
end

function Queries._buildSetSourceSavedSearchesMutation(source_id, saved_searches_json)
    return json.encode({
        query = "mutation SET_SOURCE_METAS($input: SetSourceMetasInput!) { setSourceMetas(input: $input) { metas { key value sourceId } } }",
        variables = {
            input = {
                items = {
                    {
                        sourceIds = { tostring(source_id or "") },
                        metas = {
                            {
                                key = SAVED_SEARCHES_META_KEY,
                                value = tostring(saved_searches_json or "{}"),
                            },
                        },
                    },
                },
            },
        },
    })
end

local function buildMangaQuery(options, fields)
    options = options or {}
    local input = {
        source = tostring(options.source_id),
        page = normalizeNumber(options.page, 1),
        type = options.type or "POPULAR",
    }
    if options.query and options.query ~= "" then
        input.query = options.query
    end
    if input.type == "SEARCH" and options.filters then
        input.filters = options.filters
    end

    return json.encode({
        query = "mutation GET_SOURCE_MANGAS_FETCH($input: FetchSourceMangaInput!) { fetchSourceManga(input: $input) { hasNextPage mangas { "
            .. fields
            .. " chapters { totalCount } source { id displayName name lang } } } }",
        variables = {
            input = input,
        },
    })
end

function Queries._buildMangaQuery(options)
    return buildMangaQuery(options, MANGA_FIELDS)
end

function Queries._buildLegacyMangaQuery(options)
    return buildMangaQuery(options, LEGACY_MANGA_FIELDS)
end

local function buildLibraryMangaQuery(options, fields)
    options = options or {}
    local variables = {
        filter = {
            inLibrary = {
                equalTo = true,
            },
        },
        first = normalizeNumber(options.first, 100),
        offset = normalizeNumber(options.offset, 0),
    }
    if options.order then
        variables.order = options.order
    end

    return json.encode({
        query = "query GET_LIBRARY_MANGAS($filter: MangaFilterInput, $first: Int, $offset: Int, $order: [MangaOrderInput!]) { mangas(filter: $filter, first: $first, offset: $offset, order: $order) { totalCount nodes { "
            .. fields
            .. " unreadCount source { id displayName name lang } categories { nodes { id name order } } firstUnreadChapter { id name chapterNumber sourceOrder scanlator isRead lastPageRead lastReadAt } } } }",
        variables = variables,
    })
end

function Queries._buildLibraryMangaQuery(options)
    return buildLibraryMangaQuery(options, MANGA_FIELDS)
end

function Queries._buildLegacyLibraryMangaQuery(options)
    return buildLibraryMangaQuery(options, LEGACY_MANGA_FIELDS)
end

local function buildMangaByIdQuery(manga_id, fields)
    return json.encode({
        query = "query GET_MANGA_BY_ID($filter: MangaFilterInput, $first: Int) { mangas(filter: $filter, first: $first) { totalCount nodes { "
            .. fields
            .. " source { id displayName name lang } } } }",
        variables = {
            filter = {
                id = {
                    equalTo = tonumber(manga_id) or manga_id,
                },
            },
            first = 1,
        },
    })
end

function Queries._buildMangaByIdQuery(manga_id)
    return buildMangaByIdQuery(manga_id, MANGA_FIELDS)
end

function Queries._buildLegacyMangaByIdQuery(manga_id)
    return buildMangaByIdQuery(manga_id, LEGACY_MANGA_FIELDS)
end

function Queries._buildCategoryQuery()
    return json.encode({
        query = "query GET_LIBRARY_CATEGORIES { categories { nodes { id name order mangas { totalCount } } } }",
    })
end

function Queries._buildUpdateMangaLibraryMutation(manga_id, in_library)
    return json.encode({
        query = "mutation UPDATE_MANGA_LIBRARY($input: UpdateMangaInput!) { updateManga(input: $input) { manga { id inLibrary inLibraryAt } } }",
        variables = {
            input = {
                id = tonumber(manga_id) or manga_id,
                patch = {
                    inLibrary = in_library == true,
                },
            },
        },
    })
end

local function buildRefreshMangaMutation(manga_id, fields)
    return json.encode({
        query = "mutation REFRESH_MANGA($manga: FetchMangaInput!, $chapters: FetchChaptersInput!) { fetchManga(input: $manga) { manga { "
            .. fields
            .. " source { id displayName name lang } } } fetchChapters(input: $chapters) { chapters { id name chapterNumber sourceOrder scanlator isRead lastPageRead lastReadAt } } }",
        variables = {
            manga = {
                id = tonumber(manga_id) or manga_id,
            },
            chapters = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

function Queries._buildRefreshMangaMutation(manga_id)
    return buildRefreshMangaMutation(manga_id, MANGA_FIELDS)
end

function Queries._buildLegacyRefreshMangaMutation(manga_id)
    return buildRefreshMangaMutation(manga_id, LEGACY_REFRESH_MANGA_FIELDS)
end

function Queries._buildChapterQuery(manga_id)
    return json.encode({
        query = "mutation GET_MANGA_CHAPTERS_FETCH($input: FetchChaptersInput!) { fetchChapters(input: $input) { chapters { id name chapterNumber sourceOrder scanlator isRead lastPageRead lastReadAt } } }",
        variables = {
            input = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

function Queries._buildChapterPagesQuery(chapter_id)
    return json.encode({
        query = "mutation Pages($input: FetchChapterPagesInput!) { fetchChapterPages(input: $input) { pages } }",
        variables = {
            input = {
                chapterId = tonumber(chapter_id) or chapter_id,
            },
        },
    })
end

function Queries._buildStoredChapterQuery(manga_id)
    return json.encode({
        query = "query GET_CHAPTERS_MANGA($filter: ChapterFilterInput, $first: Int, $order: [ChapterOrderInput!]) { chapters(filter: $filter, first: $first, order: $order) { totalCount nodes { id name chapterNumber sourceOrder scanlator isRead lastPageRead lastReadAt } } }",
        variables = {
            filter = {
                mangaId = {
                    equalTo = tonumber(manga_id) or manga_id,
                },
            },
            -- Long-running series run well past a couple hundred chapters, and a
            -- truncated list silently hides the tail from the menu and from
            -- next-chapter navigation.
            first = 5000,
            order = {
                {
                    by = "SOURCE_ORDER",
                },
            },
        },
    })
end

local function buildChapterFeedQuery(kind, first, library_filter, include_progress)
    local filter
    local order_by
    if kind == "history" then
        -- Suwayomi exposes Kotlin Long as a GraphQL string scalar.
        filter = { lastReadAt = { greaterThan = "0" } }
        order_by = "LAST_READ_AT"
    else
        filter = library_filter and { inLibrary = { equalTo = true } } or nil
        order_by = "FETCHED_AT"
    end
    local fields = table.concat({
        "id name chapterNumber sourceOrder scanlator isRead",
        include_progress ~= false and "lastPageRead lastReadAt fetchedAt" or "lastReadAt fetchedAt",
        "manga { " .. MANGA_FIELDS .. " source { id displayName name lang } }",
    }, " ")
    return json.encode({
        query = "query GET_CHAPTER_FEED($filter: ChapterFilterInput, $first: Int, $order: [ChapterOrderInput!]) { chapters(filter: $filter, first: $first, order: $order) { nodes { "
            .. fields
            .. " } } }",
        variables = {
            filter = filter,
            first = normalizeNumber(first, 100),
            order = {
                { by = order_by, byType = "DESC" },
            },
        },
    })
end

function Queries._buildHistoryQuery(first, include_progress)
    return buildChapterFeedQuery("history", first, false, include_progress)
end

function Queries._buildUpdatesQuery(first, library_filter, include_progress)
    return buildChapterFeedQuery("updates", first, library_filter ~= false, include_progress)
end

function Queries._buildUpdateChapterReadMutation(chapter_id, is_read)
    local cid = tonumber(chapter_id) or chapter_id
    local patch_str = string.format("isRead: %s, lastPageRead: 1", is_read == true and "true" or "false")
    local query_str
    if type(cid) == "number" then
        query_str = string.format("mutation { updateChapter(input: { id: %d, patch: { %s } }) { chapter { id isRead lastReadAt } } }", cid, patch_str)
    else
        query_str = string.format("mutation { updateChapter(input: { id: %s, patch: { %s } }) { chapter { id isRead lastReadAt } } }", json.encode(tostring(cid)), patch_str)
    end
    return json.encode({ query = query_str })
end

function Queries._buildUpdateChapterProgressMutation(chapter_id, is_read, last_page_read)
    local page_num = math.max(0, math.floor(tonumber(last_page_read) or 0))
    local cid = tonumber(chapter_id) or chapter_id
    local patch_str = string.format("lastPageRead: %d", page_num)
    if is_read == true then
        patch_str = patch_str .. ", isRead: true"
    end
    local query_str
    if type(cid) == "number" then
        query_str = string.format("mutation { updateChapter(input: { id: %d, patch: { %s } }) { chapter { id isRead lastPageRead lastReadAt } } }", cid, patch_str)
    else
        query_str = string.format("mutation { updateChapter(input: { id: %s, patch: { %s } }) { chapter { id isRead lastPageRead lastReadAt } } }", json.encode(tostring(cid)), patch_str)
    end
    return json.encode({ query = query_str })
end

function Queries._buildUpdateChaptersReadMutation(chapter_ids, is_read)
    local ids = {}
    for _, chapter_id in ipairs(chapter_ids or {}) do
        table.insert(ids, tonumber(chapter_id) or chapter_id)
    end

    return json.encode({
        query = "mutation UPDATE_CHAPTERS_READ($input: UpdateChaptersInput!) { updateChapters(input: $input) { chapters { id isRead } } }",
        variables = {
            input = {
                ids = ids,
                patch = {
                    isRead = is_read == true,
                },
            },
        },
    })
end

function Queries._buildMarkChapterReadMutation(chapter_id)
    return Queries._buildUpdateChapterReadMutation(chapter_id, true)
end

function Queries._buildMarkChapterUnreadMutation(chapter_id)
    return Queries._buildUpdateChapterReadMutation(chapter_id, false)
end

function Queries._buildTrackersQuery()
    return json.encode({
        query = "query GET_TRACKERS { trackers { nodes { id name isLoggedIn isTokenExpired } } }",
    })
end

function Queries._buildMangaTrackRecordsQuery(manga_id)
    return json.encode({
        query = "query GET_MANGA_TRACK_RECORDS($mangaId: Int) { trackRecords(condition: { mangaId: $mangaId }) { nodes { id trackerId remoteId title lastChapterRead totalChapters status displayScore tracker { id name isLoggedIn } } } }",
        variables = {
            mangaId = tonumber(manga_id) or manga_id,
        },
    })
end

function Queries._buildSearchTrackerQuery(tracker_id, query)
    return json.encode({
        query = "query SEARCH_TRACKER($input: SearchTrackerInput!) { searchTracker(input: $input) { trackSearches { remoteId title trackerId publishingStatus totalChapters trackingUrl } } }",
        variables = {
            input = {
                trackerId = tonumber(tracker_id) or tracker_id,
                query = tostring(query or ""),
            },
        },
    })
end

function Queries._buildBindTrackMutation(manga_id, tracker_id, remote_id)
    return json.encode({
        query = "mutation BIND_TRACK($input: BindTrackInput!) { bindTrack(input: $input) { trackRecord { id trackerId remoteId title lastChapterRead } } }",
        variables = {
            input = {
                mangaId = tonumber(manga_id) or manga_id,
                trackerId = tonumber(tracker_id) or tracker_id,
                remoteId = tostring(remote_id),
            },
        },
    })
end

function Queries._buildUnbindTrackMutation(record_id)
    return json.encode({
        query = "mutation UNBIND_TRACK($input: UnbindTrackInput!) { unbindTrack(input: $input) { trackRecord { id } } }",
        variables = {
            input = {
                recordId = tonumber(record_id) or record_id,
            },
        },
    })
end

function Queries._buildTrackProgressMutation(manga_id)
    return json.encode({
        query = "mutation TRACK_PROGRESS($input: TrackProgressInput!) { trackProgress(input: $input) { trackRecords { id trackerId lastChapterRead } } }",
        variables = {
            input = {
                mangaId = tonumber(manga_id) or manga_id,
            },
        },
    })
end

return Queries
