# Changelog

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
