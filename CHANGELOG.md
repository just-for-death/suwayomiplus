# Changelog

## v1.0.8-reader

Fork release based on [LK4D4/suwayomi.koplugin](https://github.com/LK4D4/suwayomi.koplugin) with online streaming, cache-backed KOReader reader mode, in-reader chapter navigation, Suwayomi tracker UI (MAL / AniList), bulk downloads, and reading-cache controls.

### Highlights

- Tap a chapter to **read online** (stream pages) by default.
- Long-press for **Open in reader** (size-capped chapter cache → KOReader document reader) or **Keep offline** (permanent CBZ).
- Settings: chapter-tap behaviour, reading-cache limit / clear.
- Next / previous chapter and chapter list from inside the reader (also as dispatcher actions).
- Tracker bind / unbind / progress sync through Suwayomi.
- Download queue improvements: longer archive timeout, zombie reaping, quieter status refreshes, cache vs keep-offline purpose.
- Fixes for library pagination, false “finished” from history alone, stream close / mark-read, and reader chapter-list persistence per manga.

### References

- Upstream: https://github.com/LK4D4/suwayomi.koplugin
- Suwayomi-Server: https://github.com/Suwayomi/Suwayomi-Server
- KOReader: https://github.com/koreader/koreader
- Catalyst (mobile companion): https://github.com/just-for-death/catalyst
- koreader-komga (patterns): https://github.com/akamuraasai/koreader-komga
- rakuyomi (patterns): https://github.com/tachibana-shin/rakuyomi
