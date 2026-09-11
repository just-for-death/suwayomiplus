# Changelog

## v1.3.20

- Pre-seed fit-to-page zoom and right-to-left reading order on every newly downloaded chapter, so manga opens as a true single-page layout by default.
- Force-normalize existing sidecars via `normalizeReadingMode()` and `repairMangaReadingMode()` to clear legacy webtoon-like fractional scroll positions.
- Add `tools/migrate_manga_reading_mode.lua` — recursive idempotent batch migration script to reset all downloaded chapter sidecars to manga reading mode.
- `repairMangaDirectory()` now also calls `repairMangaReadingMode()` so directory repairs reset reading mode.

## v1.3.19

- Add long-press / hold gesture on manga cards in Manga Library to open the manga quick action menu.
- Add Download Missing Chapters, Trackers, and Chapters shortcuts to the Manga Manager menu.
- Enhance Auto Download integration with MaxOutUI Quick Action row and homescreen modules.

## v1.3.18

- Fix read-sync ledger dropping `pending_last_page_read` (offline page progress).
- Run pending read sync in a subprocess (no UI-thread GraphQL batch).
- Reconcile finished local CBZs into pending sync on Downloads open and plugin init.
- Set `pending_read_state` when KOReader marks chapters finished in the chapter list.
- Save ledger after chapter-menu refresh for bulk mark-read.
- Auto-download: cap missing queues; on-add also tracks the manga; clearer settings labels.

## v1.3.17

- Auto-download: on library add (Off / Missing / Latest), tracked manga list,
  quiet queue helper, Downloads settings entries, and manga actions to add or
  manage auto-download modes.

## v1.3.16

- Two-way read sync when opening a manga: always pull latest `isRead` from
  Suwayomi (Resume / next unread / History / chapter list), then push any
  pending Kindle-side read marks.
- Grey out read chapter titles in the chapter list (`dimmed` → dark gray).

## v1.3.15

- Stop rebuilding the chapter list on every download page-progress tick. Progress
  updates refresh the Downloads menu only; chapter menus refresh on state changes
  (queued / downloaded / failed) and only while that menu is actually visible.
- Guard `refreshChapterMenu` with `pcall` so a mid-rebuild widget (`nil dimen`)
  cannot tear down KOReader.

## v1.3.14

- Debounce chapter/downloads menu refresh during download progress (1.5s). Rebuilding
  huge chapter lists (e.g. One Piece ~400) on every page tick froze the Kindle and
  contributed to `IconButton` nil-`dimen` crashes.

## v1.3.13

- Prefer decoding the Suwayomi thumbnail to JPEG before falling back to the first
  chapter page (avoids installing a random page as the folder cover).
- Write folder covers only from the parent process after a chapter finishes, so a
  WebP-incapable download subprocess cannot lock in a page-fallback cover.

## v1.3.12

- Fix folder covers on Kindle: BusyBox `unzip` has no `-Z1`, so the CBZ page
  fallback never ran after WebP thumbnail conversion failed. Parse `unzip -l`
  instead and copy JPEG chapter pages directly when possible.
- Prefer first-chapter JPEG pages over WebP/PNG thumbnails that need a decoder
  the download subprocess often lacks.
- Keep download-directory path casing aligned with the live filesystem
  (`Books/Manga` vs `Books/manga`).

## v1.3.8

- Fix download-queue busy-loop when an inline job is deferred while another job is active (`max_parallel > 1`).
- Set chapter status to `downloaded`/`skipped` on successful `finishFromProgress` (not only on the failed-but-archive-exists path).
- Heal stale `downloading`/`queued`/`failed` menu status when the chapter archive already exists on disk.
- Prefer KOReader `file.sdr` sidecars, fall back to legacy `file.cbz.sdr`, and use `DocSettings:getSidecarDir` when available.
- Defer manga cover HTTP off the download hot path via `UIManager:scheduleIn`.
- Persist richer manga fields in JobStore (`author`, `artist`, `description`, thumbnail URLs).
- Stream CRC-32 for STORED zip packing in 64KB chunks instead of reading whole pages into memory for checksums.
- Remove empty `.suwayomi_tmp` staging directories after cleanup/finalize.

## v1.3.7

- Write chapter sidecars to KOReader's real location (`file.sdr`, not `file.cbz.sdr`) and migrate any legacy `.cbz.sdr` folders.
- Merge chapter sidecar metadata instead of overwriting reader progress; always keep series/title/Suwayomi IDs.
- Rebuild `.manga_index.lua` from every on-disk CBZ so early chapters are never dropped from the index.
- Add `repairMangaDirectory` to fix metadata/covers/bookinfo for a whole manga folder.
- Mark visible `cover.jpg` / `folder.jpg` as ignored in CoverBrowser; prefer hidden `.cover.jpg` for MaxOutUI.
- Validate downloaded page bytes are real JPEG/PNG/WebP/GIF before packing CBZs.

## v1.3.6

- Keep in-progress downloads under a hidden `.suwayomi_tmp/` folder so CoverBrowser never indexes `.part.pages` dirs or half-written archives.
- After each finished chapter (and rewritten folder covers), clear CoverBrowser bookinfo rows so a crash-time "too many interruptions" mark cannot permanently hide thumbnails.

## v1.3.5

- Fix manga folder covers: download the real thumbnail and write proper JPEGs to `cover.jpg`, `folder.jpg`, and `.cover.jpg` (no more WebP-as-`.jpg` or SWTHUMB1 cache copies that show as lines).

## v1.0.4

- Add real-time per-page progress sync directly hooked into page turns (`syncStreamPageProgress`).
- Send 0-delay background GraphQL progress mutations to Suwayomi server.
- Automatically dim / gray out read chapters in chapter list views while keeping unread chapters bold for high e-ink contrast.
- Add **"Pin Manga (SimpleUI)"** / **"Unpin Manga (SimpleUI)"** action to Suwayomi Manga Information options menu.
- Ensure `lastPageRead >= 1` in `updateChapter` GraphQL mutations so Suwayomi server generates valid timestamps and updates reading history order.
- Fix UI crash by wrapping `UIManager:forceRePaint()` in safe `pcall` during loading feedback.

## v1.0.3

- Fix History and Updates crashing KOReader because their feed menu renderer was missing.
- Isolate feed rendering errors so they display an error instead of terminating KOReader.
- Make the online-reader long-press action explicit: **Select chapter from this manga**.
- Keep automatic next-chapter opening when turning forward after the final page.

## v1.0.2

- Fix chapter downloads failing with "Downloaded response was too large": chapter archives were capped at the 32 MB single-page limit, so any chapter over that size never downloaded. Archives now stream to disk with their own 512 MB budget.
- Fix stream viewer next/previous/select chapter using a stale chapter list when the previously browsed manga differed from the one being read.

## v1.0.1

- Fix download wiring: chapter archive API, download-aware chapter context/read actions, manga bulk downloads, reader-return fetch.

## v1.0.0

- Renamed plugin to **Suwayomi+** (`suwayomiplus.koplugin`).
- Reintroduced chapter downloads, download queue, and offline CBZ reading from the original Suwayomi plugin.
- Kept online streaming with chapter navigation and page-level progress sync.
- Kept Suwayomi History and Updates feeds.
- Kept read-state and tracker sync (MAL, AniList, etc.) via Suwayomi server.

## v2.0.0-online (internal fork, superseded)

- Online-only experiment; downloads removed.

## v1.0.8-reader

- Original Suwayomi KOReader client with cache reader, downloads, and in-reader chapter navigation.
