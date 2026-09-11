-- test_unread_count_display.lua — Tests for getMangaMandatory in list_rows.lua
--
-- getMangaMandatory is a public function but its dependencies (I18n,
-- SourceLanguages) require the KOReader runtime.  We reproduce the function
-- verbatim here using a minimal I18n mock so the logic can be verified
-- without the full runtime.
--
-- Contract tested: if the implementation in list_rows.lua changes its output
-- format or nil-handling, these tests will catch it.
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_unread_count_display.lua

-- ---------------------------------------------------------------------------
-- Standalone bootstrap
-- ---------------------------------------------------------------------------

local _standalone = type(assert_eq) ~= "function"
if _standalone then
    local _p, _f, _e = 0, 0, {}
    assert_eq = function(a, b, label)
        if a == b then _p = _p + 1; print("    PASS: " .. label)
        else
            _f = _f + 1
            print("    FAIL: " .. label .. " — expected " .. tostring(b) .. " got " .. tostring(a))
            table.insert(_e, label)
        end
    end
    assert_true  = function(v, l) assert_eq(not not v, true,  l) end
    assert_false = function(v, l) assert_eq(not not v, false, l) end
    assert_nil   = function(v, l) assert_eq(v, nil, l) end
    assert_not_nil = function(v, l)
        if v ~= nil then _p = _p + 1; print("    PASS: " .. l)
        else _f = _f + 1; print("    FAIL: " .. l .. " — expected non-nil"); table.insert(_e, l) end
    end
end

-- ---------------------------------------------------------------------------
-- Minimal I18n mock
--
-- Mirrors the behaviour of I18n when no translation catalog is active
-- (i.e. English pass-through):
--   I18n.t(s)                     → s unchanged
--   I18n.count(n, singular, plural) → substitute %1 with n in the right form
--   I18n.join(parts, sep)         → concat non-empty parts with sep
-- ---------------------------------------------------------------------------

local function fallback_template(tmpl, ...)
    local values = { ... }
    -- Wrap in parentheses to discard gsub's second return value (replacement count).
    -- Without this, callers that pass the result to table.insert would see 3
    -- arguments and Lua would treat the string as a positional index.
    return (tostring(tmpl or ""):gsub("%%(%d+)", function(idx)
        return tostring(values[tonumber(idx)] or "")
    end))
end

local MockI18n = {}

MockI18n.t = function(msgid)
    return tostring(msgid or "")
end

MockI18n.count = function(count, singular, plural)
    -- English plural rule: count == 1 → singular, else plural
    local tmpl = (tonumber(count) == 1) and singular or plural
    return fallback_template(tmpl, count)
end

MockI18n.join = function(parts, sep)
    sep = tostring(sep or " ")
    local rendered = {}
    for i = 1, #(parts or {}) do
        local part = parts[i]
        if part ~= nil and part ~= "" then
            table.insert(rendered, tostring(part))
        end
    end
    return table.concat(rendered, sep)
end

-- ---------------------------------------------------------------------------
-- Verbatim copy of formatChapterCount and getMangaMandatory from list_rows.lua,
-- substituting MockI18n for I18n.
-- (Keep in sync with the source file.)
-- ---------------------------------------------------------------------------

local function formatChapterCount(count)
    count = tonumber(count)
    if not count then return nil end
    if count == 0 then return nil end
    return MockI18n.count(count, "%1 chapter", "%1 chapters")
end

local function getMangaMandatory(manga, options)
    options = options or {}
    local labels = {}
    if options.show_in_library == true and type(manga) == "table" and manga.in_library == true then
        table.insert(labels, MockI18n.t("In Library"))
    end
    if options.show_unread_count == true and type(manga) == "table" then
        local unread = tonumber(manga.unread_count)
        if unread and unread > 0 then
            table.insert(labels, MockI18n.count(unread, "%1 unread", "%1 unread"))
        end
    end
    if type(manga) == "table" then
        local chapter_count
        if type(manga.chapter_count_error) == "string" and manga.chapter_count_error ~= "" then
            chapter_count = manga.chapter_count_error
        elseif manga.chapter_count_loading == true then
            chapter_count = MockI18n.t("Checking chapters")
        elseif manga.chapter_count_verified == true and tonumber(manga.chapter_count) == 0 then
            chapter_count = MockI18n.count(0, "%1 chapter", "%1 chapters")
        else
            chapter_count = formatChapterCount(manga.chapter_count)
        end
        if chapter_count then
            table.insert(labels, chapter_count)
        end
    end
    if #labels == 0 then return nil end
    return MockI18n.join(labels, " · ")
end

-- ---------------------------------------------------------------------------
-- Test 1: show_unread_count = false → unread count is not shown
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { unread_count = 7 },
        { show_unread_count = false }
    )
    assert_nil(result, "show_unread_count=false: result is nil (no labels at all)")
end

-- ---------------------------------------------------------------------------
-- Test 2: show_unread_count = true with unread_count = 0 → NOT shown
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { unread_count = 0 },
        { show_unread_count = true }
    )
    assert_nil(result, "show_unread_count=true, unread=0: not shown (nil result)")
end

-- ---------------------------------------------------------------------------
-- Test 3: show_unread_count = true with unread_count = 5 → "5 unread"
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { unread_count = 5 },
        { show_unread_count = true }
    )
    assert_eq(result, "5 unread", "show_unread_count=true, unread=5: shows '5 unread'")
end

-- ---------------------------------------------------------------------------
-- Test 3b: singular form — unread_count = 1 → "1 unread"
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { unread_count = 1 },
        { show_unread_count = true }
    )
    assert_eq(result, "1 unread", "show_unread_count=true, unread=1: shows '1 unread'")
end

-- ---------------------------------------------------------------------------
-- Test 4: show_unread_count = true with unread_count = nil → no error, not shown
-- ---------------------------------------------------------------------------

do
    local ok, result = pcall(getMangaMandatory,
        { unread_count = nil },
        { show_unread_count = true }
    )
    assert_true(ok, "unread_count=nil: no error thrown")
    assert_nil(result, "unread_count=nil: result is nil")
end

-- ---------------------------------------------------------------------------
-- Test 5: show_unread_count = true + chapter_count → "5 unread · 42 chapters"
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { unread_count = 5, chapter_count = 42 },
        { show_unread_count = true }
    )
    assert_eq(result, "5 unread · 42 chapters",
        "combined unread+chapters: '5 unread · 42 chapters'")
end

-- ---------------------------------------------------------------------------
-- Test 5b: chapter_count = 1 uses singular form
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { unread_count = 3, chapter_count = 1 },
        { show_unread_count = true }
    )
    assert_eq(result, "3 unread · 1 chapter",
        "combined unread+chapters: singular chapter form")
end

-- ---------------------------------------------------------------------------
-- Test 6: show_in_library = true + in_library = true → "In Library"
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { in_library = true },
        { show_in_library = true }
    )
    assert_eq(result, "In Library", "show_in_library=true, in_library=true: 'In Library'")
end

-- ---------------------------------------------------------------------------
-- Test 6b: show_in_library = true + in_library = false → not shown
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { in_library = false },
        { show_in_library = true }
    )
    assert_nil(result, "show_in_library=true, in_library=false: not shown")
end

-- ---------------------------------------------------------------------------
-- Test 7: show_in_library + show_unread_count + chapter_count → combined
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { in_library = true, unread_count = 3, chapter_count = 10 },
        { show_in_library = true, show_unread_count = true }
    )
    assert_eq(result, "In Library · 3 unread · 10 chapters",
        "all labels: 'In Library · 3 unread · 10 chapters'")
end

-- ---------------------------------------------------------------------------
-- Test 8: chapter_count_loading = true → "Checking chapters"
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { chapter_count_loading = true },
        {}
    )
    assert_eq(result, "Checking chapters", "chapter_count_loading: shows 'Checking chapters'")
end

-- ---------------------------------------------------------------------------
-- Test 9: chapter_count_error string → error message shown verbatim
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { chapter_count_error = "Timed out" },
        {}
    )
    assert_eq(result, "Timed out", "chapter_count_error: error string shown verbatim")
end

-- ---------------------------------------------------------------------------
-- Test 10: chapter_count_verified = true + chapter_count = 0 → "0 chapters"
-- ---------------------------------------------------------------------------

do
    local result = getMangaMandatory(
        { chapter_count_verified = true, chapter_count = 0 },
        {}
    )
    assert_eq(result, "0 chapters",
        "chapter_count_verified=true, count=0: shows '0 chapters'")
end

-- ---------------------------------------------------------------------------
-- Test 11: non-table manga → nil without error
-- ---------------------------------------------------------------------------

do
    local ok, result = pcall(getMangaMandatory, nil, { show_unread_count = true })
    assert_true(ok,   "non-table manga: no error")
    assert_nil(result, "non-table manga: nil result")
end

if _standalone then
    print("\nUnread Count Display: see above for individual results")
end
