-- tools/migrate_manga_reading_mode.lua — batch-migrate existing manga sidecars
-- to true manga reading mode (Fit to page zoom, right-to-left paging, no
-- webtoon-like vertical scroll splits).
--
-- This makes Fix 3 from MANGA_READING_MODE_ISSUE_AND_FIX.txt repeatable:
-- instead of hand-editing every chapter's .sdr/metadata.cbz.lua, one pass
-- force-normalizes every downloaded chapter in a tree. For each directory that
-- contains chapter CBZs it also repairs the sidecars, clears fractional
-- page_positions, and rebuilds the .manga_index.lua (via repairMangaDirectory).
--
-- The scan is recursive and idempotent — safe to re-run at any time. It covers
-- both layouts: Books/Manga/<Title>/ and Books/Manga/<Source>/<Title>/.
--
-- Usage (KOReader → File manager → Search → Terminal, or ssh on the Kindle):
--   lua /mnt/us/koreader/plugins/suwayomiplus.koplugin/tools/migrate_manga_reading_mode.lua
--   lua .../migrate_manga_reading_mode.lua /mnt/us/Books/Manga
--
-- Run from a desktop Lua interpreter for a trial pass on a test tree:
--   lua tools/migrate_manga_reading_mode.lua /tmp/manga-test-tree

local function scriptDir()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*[/\\])") or "./"
end

local PLUGIN_ROOT = (scriptDir():gsub("/+$", "")):match("^(.*)/tools$") or scriptDir() .. ".."
local KOREADER_ROOT = "/mnt/us/koreader"

-- Adapt package paths so require("suwayomi/...") resolves in both runtimes.
package.path = PLUGIN_ROOT
    .. "/?.lua;" .. KOREADER_ROOT .. "/common/?.lua;" .. package.path
package.cpath = KOREADER_ROOT .. "/common/libs/?.so;" .. package.cpath

local ok_fs, lfs = pcall(require, "suwayomi/fs")
if not ok_fs or not lfs or not lfs.dir then
    print("ERROR: filesystem module (lfs) unavailable. Run from KOReader's terminal")
    print("       (lua .../tools/migrate_manga_reading_mode.lua) or install Luarocks lfs.")
    os.exit(1)
end

local MangaMetadata = require("suwayomi/downloads/manga_metadata")

local function hasCbzEntries(dir)
    for name in lfs.dir(dir) do
        if type(name) == "string" and name:match("%.cbz$") and not name:match("%.part") then
            local path = dir .. "/" .. name
            if lfs.attributes(path, "mode") == "file" then
                return true
            end
        end
    end
    return false
end

local function collectMangaDirs(root)
    local found = {}
    local function walk(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then
            return
        end
        local ok, iter, state, var = pcall(lfs.dir, dir)
        if not ok then
            return
        end
        for name in iter, state, var do
            if type(name) == "string" and name ~= "." and name ~= ".." and not name:match("^%.") then
                local path = dir .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    if hasCbzEntries(path) then
                        found[#found + 1] = path
                    end
                    walk(path)
                end
            end
        end
    end
    walk(root)
    return found
end

local root = arg and arg[1] or "/mnt/us/Books/Manga"
root = tostring(root):gsub("/+$", "")
if root == "" then
    root = "/mnt/us/Books/Manga"
end
if lfs.attributes(root, "mode") ~= "directory" then
    print("ERROR: manga root not found: " .. root)
    os.exit(1)
end

print("Manga reading-mode migration")
print("Root: " .. root)
print("----------------------------------------")

local manga_dirs = collectMangaDirs(root)
if #manga_dirs == 0 then
    print("No directories with chapter CBZs found — nothing to migrate.")
    os.exit(0)
end

local migrated_dirs = 0
local repaired_chapters = 0
for _, manga_dir in ipairs(manga_dirs) do
    local ok, err = pcall(function()
        -- Repair also rebuilds .manga_index.lua; no credentials → skips covers.
        return MangaMetadata.repairMangaDirectory(manga_dir, {})
    end)
    if ok and err then
        migrated_dirs = migrated_dirs + 1
        print("OK    " .. manga_dir)
    else
        print("FAIL  " .. manga_dir .. " — " .. tostring(err))
    end
end

-- Count how many chapter sidecars are actually manga-mode now.
for _, manga_dir in ipairs(manga_dirs) do
    for name in lfs.dir(manga_dir) do
        if type(name) == "string" and name:match("%.cbz$") and not name:match("%.part") then
            local base = name:match("^(.*)%.[^./]+$") or name
            if lfs.attributes(manga_dir .. "/" .. base .. ".sdr", "mode") == "directory" then
                repaired_chapters = repaired_chapters + 1
            end
        end
    end
end

print("----------------------------------------")
print(string.format("Done: %d manga folder(s) migrated (%d chapter sidecars present).",
    migrated_dirs, repaired_chapters))
print("Open any chapter and verify: whole page fits, RTL paging, 1 tap = 1 page turn.")