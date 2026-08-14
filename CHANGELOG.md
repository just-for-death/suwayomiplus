# Changelog

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
