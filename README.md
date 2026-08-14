# Suwayomi+ for KOReader

A [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server) client for [KOReader](https://github.com/koreader/koreader): stream online, download for offline, and sync progress with your server and trackers.

## Features

- Browse manga in your Suwayomi library and installed sources.
- **Stream** chapters online with next/previous/chapter-picker navigation.
- **Download** chapters as CBZ for offline reading in KOReader's native reader.
- Sync read state and page progress back to Suwayomi (continue on phone, iPad, etc.).
- View Suwayomi **History** and library **Updates**.
- Tracker sync (MAL, AniList, etc.) through Suwayomi.

## Requirements

- KOReader
- A reachable Suwayomi Server with desired source extensions installed
- Basic Auth credentials if enabled on the server

## Installation

Copy `suwayomiplus.koplugin` to:

```text
<koreader-root>/plugins/suwayomiplus.koplugin/
```

Restart KOReader, open **Search → Suwayomi+**, enter server URL and credentials, and test the connection.

Existing settings from earlier `suwayomi.koplugin` installs are retained automatically.

## Home

- **Library** — manga in the Suwayomi library
- **Browse** — installed sources and search
- **Downloads** — active queue and downloaded chapters
- **History** — recently read chapters from Suwayomi
- **Updates** — newly fetched library chapters
- **Sync** — retry pending read-state changes
- **Settings** — connection, downloads, and browse preferences

## References

- [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server)
- [KOReader](https://github.com/koreader/koreader)
- [Catalyst (iOS/Android Suwayomi client)](https://github.com/just-for-death/catalyst)
