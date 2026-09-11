# Suwayomi+ for KOReader

A [Suwayomi Server](https://github.com/Suwayomi/Suwayomi-Server) client for [KOReader](https://github.com/koreader/koreader): **stream first**, download when you need offline, sync progress and trackers.

Built for primary manga reading on e-ink (Kindle, Kobo, etc.), especially over Tailscale / intermittent networks.

---

## Credits

- **Suwayomi Server** — [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server)
- **KOReader** — [koreader/koreader](https://github.com/koreader/koreader)
- **UI companion** — [MaxOutUI](https://github.com/just-for-death/maxoutui) (fork of SimpleUI by Doctor Hetfield)
- **Offline sync companion** — [MangaSync](https://github.com/just-for-death/mangasync)

Author: [just-for-death](https://github.com/just-for-death)

---

## Features

### Online-first reading
- **Stream** chapters with prefetch, page sync, and next/prev chapter navigation
- **Continue Reading** — jump to the first unread chapter from history
- Chapter tap default is **quick view / stream** (download is secondary)

### Library & browse
- Paginated library with **unread-first sort** and unread counts on rows
- Source browse (popular / latest / search / filters), global search
- History, Updates, categories, trackers (MAL / AniList via server)

### Downloads as a book
Each manga is a **folder = book**, chapters = files inside it:

```text
Books/Manga/<Source>/<Manga Title>/
  .cover.jpg
  .manga_index.lua
  Ch. 001 - Romance Dawn [id-123].cbz
  Ch. 001 - Romance Dawn [id-123].cbz.sdr/metadata.cbz.lua
  Ch. 002 - ...
```

KOReader metadata on each chapter CBZ:

| Field | Meaning |
|---|---|
| `series` | Manga title (the book) |
| `title` | `Ch. 1 - Chapter Name` (the chapter) |
| `series_index` | Chapter number for ordering |
| `suwayomi_chapter_id` / `suwayomi_manga_id` | Used by MangaSync |

Browse the manga folder like a multi-chapter book; open any chapter CBZ to read. MangaSync (or Suwayomi+ read-sync) pushes progress back to the server.

### Network resilience (Tailscale / sleep)
After Kindle sleep, Tailscale often needs a few seconds. **WakeupGuard** detects long silence and retries GraphQL with longer delays (up to 5 attempts × 4s) instead of failing immediately.

### MaxOutUI integration
Pins, Continue Reading, library / updates / categories / status modules on the MaxOutUI home screen.

---

## Requirements

- KOReader
- Reachable Suwayomi Server with sources installed
- Basic Auth if enabled on the server

---

## Install

Copy to:

```text
<koreader-root>/plugins/suwayomiplus.koplugin/
```

Restart KOReader → **Search → Suwayomi+** → enter server URL / credentials → test connection.

Optional:

- [MaxOutUI](https://github.com/just-for-death/maxoutui) for the home-screen manga UI
- [MangaSync](https://github.com/just-for-death/mangasync) to sync **downloaded** chapter CBZ progress when you close the document

---

## Tests

```bash
lua tests/test_runner.lua
```

Covers library sort, unread labels, Continue Reading selection, wakeup retries, paths/FAT32 limits, manga metadata, and MangaSync queue logic.

---

## License

See repository license / upstream Suwayomi and KOReader conventions.
