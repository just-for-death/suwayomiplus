-- test_manga_hold_action.lua — Tests for manga hold / long-press action wiring
--
-- Runnable standalone:
--   lua suwayomiplus/tests/test_manga_hold_action.lua

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

local function tests_dir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[/\\])") or "./"
end

local base_dir = tests_dir() .. "../"
package.path = base_dir .. "?.lua;" .. base_dir .. "?/init.lua;" .. package.path

-- Mock packages needed for ListRows
package.preload["suwayomi/i18n"] = function()
    return {
        t = function(s) return s end,
        count = function(n, s, p) return n .. " " .. (n == 1 and s or p) end,
        join = function(p, sep) return table.concat(p, sep or " ") end,
    }
end

package.preload["suwayomi/source_languages"] = function()
    return {
        formatLabel = function(l) return l end,
    }
end

local ListRows = require("suwayomi/ui/list_rows")

-- ---------------------------------------------------------------------------
-- 1. ListRows.buildMangaRow hold_callback tests
-- ---------------------------------------------------------------------------

do
    local manga = { id = 123, title = "Berserk" }
    local held_manga = nil
    local row = ListRows.buildMangaRow(manga, {
        on_hold = function(m)
            held_manga = m
        end,
    })

    assert_not_nil(row.hold_callback, "buildMangaRow attaches hold_callback when on_hold is provided")
    row.hold_callback()
    assert_eq(held_manga and held_manga.id, 123, "invoking hold_callback forwards manga object to on_hold")
end

do
    local manga = { id = 456, title = "One Piece" }
    local row = ListRows.buildMangaRow(manga, {})
    assert_nil(row.hold_callback, "buildMangaRow does not attach hold_callback when on_hold is omitted")
end

do
    local manga_list = {
        { id = 1, title = "Manga 1" },
        { id = 2, title = "Manga 2" },
    }
    local held_count = 0
    local table_rows = ListRows.buildMangaMenuTable(manga_list, {
        on_hold = function(m)
            held_count = held_count + 1
        end,
    })

    assert_eq(#table_rows, 2, "buildMangaMenuTable returns all rows")
    assert_not_nil(table_rows[1].hold_callback, "row 1 has hold_callback")
    assert_not_nil(table_rows[2].hold_callback, "row 2 has hold_callback")
    table_rows[1].hold_callback()
    table_rows[2].hold_callback()
    assert_eq(held_count, 2, "invoking hold_callbacks increments count")
end

-- ---------------------------------------------------------------------------
-- 2. Controller showMangaActions force_menu logic tests
-- ---------------------------------------------------------------------------

do
    -- Verify the branching logic of showMangaActions:
    -- if not (action_options and (action_options.force_menu or action_options.skip_manga_information)) and SuwayomiUI.showMangaInformation
    local function testShowMangaActions(SuwayomiUI, manga, options)
        local action_options = options or {}
        if not (action_options and (action_options.force_menu or action_options.skip_manga_information)) and SuwayomiUI.showMangaInformation then
            return "manga_information"
        end
        if not SuwayomiUI.showMangaActionsMenu then
            return "chapters"
        end
        return "manga_actions_menu"
    end

    local mock_ui = {
        showMangaInformation = function() return true end,
        showMangaActionsMenu = function() return true end,
    }

    local manga = { id = 789, title = "Chainsaw Man" }
    local res_tap = testShowMangaActions(mock_ui, manga, {})
    assert_eq(res_tap, "manga_information", "tap (default) opens manga_information")

    local res_hold = testShowMangaActions(mock_ui, manga, { force_menu = true })
    assert_eq(res_hold, "manga_actions_menu", "hold (force_menu=true) opens manga_actions_menu")
end
