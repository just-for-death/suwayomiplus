# Changelog

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
