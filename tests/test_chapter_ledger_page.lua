-- test_chapter_ledger_page.lua — pending_last_page_read must survive save/load.

local _standalone = type(assert_eq) ~= "function"
if _standalone then
    local _p, _f = 0, 0
    assert_eq = function(a, b, label)
        if a == b then _p = _p + 1; print("    PASS: " .. label)
        else _f = _f + 1; print("    FAIL: " .. label .. " — expected " .. tostring(b) .. " got " .. tostring(a)) end
    end
    assert_true = function(v, l) assert_eq(not not v, true, l) end
    assert_not_nil = function(v, l)
        if v ~= nil then _p = _p + 1; print("    PASS: " .. l)
        else _f = _f + 1; print("    FAIL: " .. l) end
    end
end

package.loaded["datastorage"] = nil
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/tmp" end,
    }
end

package.loaded["luasettings"] = nil
local store = {}
package.preload["luasettings"] = function()
    return {
        open = function(_path)
            return {
                readSetting = function(_self, key, default)
                    if store[key] ~= nil then return store[key] end
                    return default
                end,
                saveSetting = function(_self, key, value)
                    store[key] = value
                    return _self
                end,
                delSetting = function(_self, key)
                    store[key] = nil
                    return _self
                end,
                flush = function(_self) return _self end,
            }
        end,
    }
end

package.loaded["suwayomi/source_filters"] = true
package.preload["suwayomi/source_filters"] = function()
    return { normalize = function(v) return v end }
end

package.loaded["suwayomi/settings"] = nil
local Settings = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "../suwayomi/settings.lua")

do
    store = {}
    local ledger = {
        ["10:20"] = {
            manga_id = "10",
            manga_title = "Test",
            chapter_id = "20",
            chapter_name = "Ch 1",
            read = false,
            pending_read_sync = true,
            pending_read_state = false,
            pending_last_page_read = 12,
            path = "/Books/Manga/Test/Ch. 1.cbz",
        },
    }
    Settings:saveChapterLedger(ledger)
    local loaded = Settings:loadChapterLedger()
    local entry = loaded["10:20"]
    assert_not_nil(entry, "ledger entry survives save/load")
    assert_eq(tonumber(entry.pending_last_page_read), 12,
        "pending_last_page_read round-trips through normalize/save")
    assert_true(entry.pending_read_sync == true, "pending_read_sync preserved")
    assert_eq(entry.pending_read_state, false, "pending_read_state false preserved")
end

if _standalone then
    print("Chapter ledger page progress: done")
end
