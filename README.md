# Suwayomi Client for KOReader

Browse a self-hosted [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server) server from [KOReader](https://github.com/koreader/koreader). Tap a chapter to read it online, open it in KOReader's normal reader through a size-capped cache (so history, streaks, and statistics count), track on MAL/AniList, or download CBZ files in bulk for offline use.

This repository is maintained by [@just-for-death](https://github.com/just-for-death). It builds on the original [LK4D4/suwayomi.koplugin](https://github.com/LK4D4/suwayomi.koplugin) client.

## What's New in This Fork

- **Read online** — tap a chapter to stream pages without a permanent download (default).
- **Open in reader** — optional cache-based path that fetches a chapter into a size-capped local cache and opens it in KOReader's document reader, so SimpleUI history / currently reading / streaks work.
- **In-reader chapter navigation** — next / previous chapter, chapter list, and end-of-chapter menu (also bindable as KOReader gestures).
- **Trackers** — view and bind Suwayomi trackers such as MyAnimeList and AniList from the device.
- **Bulk downloads** — queue large chapter batches (up to 500) for offline CBZ storage.
- **Reading cache controls** — configurable cache limit with automatic cleanup of older chapters.

Tap behaviour is configurable under **Suwayomi → Settings → Reading → Chapter tap**.

## What You Need

- KOReader on your device (Kindle, Kobo, Android, Linux desktop, …).
- A Suwayomi server reachable from that device (Tailscale / VPN is fine).
- Basic Auth credentials if your Suwayomi server uses login protection.

Sources do not have to be installed before first use. You can install and update Suwayomi source extensions from the plugin's **Browse** screen.

Downloaded chapters stay on the KOReader device. The plugin does not use or manage Suwayomi's server-side download queue.

## Installation

### Manual Install (recommended for this fork)

1. Download `suwayomi.koplugin-v1.0.8-reader.zip` from the [latest release](https://github.com/just-for-death/suwayomi.koplugin/releases/latest).
2. Extract the zip.
3. Copy the extracted `suwayomi.koplugin` folder into KOReader's plugin directory.
4. Confirm the final path is exactly one plugin folder deep:

```text
<your-device-root>/koreader/plugins/suwayomi.koplugin/
```

On Android, `<your-device-root>` is usually `/sdcard`. On Kobo or Kindle, use the device storage root that contains `koreader/`. On Linux desktop, the path is usually `~/.config/koreader/plugins/suwayomi.koplugin/`.

Do not leave the files in a nested path such as `koreader/plugins/suwayomi.koplugin/suwayomi.koplugin/`.

5. Confirm the folder contains `_meta.lua`, `main.lua`, `suwayomi/`, and `l10n/` when present.
6. Restart KOReader.

To update, replace the old `suwayomi.koplugin` folder with the new release folder, then restart KOReader.

## First Run

1. Open KOReader's top menu.
2. Go to **Search** and tap **Suwayomi**.
3. Enter your Suwayomi server URL, username, and password.
4. Tap **Test connection**.
5. Choose a download folder for local CBZ files.

You can rerun setup later from **Suwayomi → Settings → Setup wizard**. To edit only the saved login, use **Settings → Connection → Login information**.

## Daily Use

Open **Suwayomi** from KOReader's **Search** menu (or add it to SimpleUI if you use that plugin):

- **Library** — manga already in your Suwayomi library.
- **Browse** — search sources, Popular / Latest lists, install or update extensions.
- **Downloads** — active, queued, and failed local downloads.
- **Sync** — send pending read/unread changes to Suwayomi.
- **Settings** — connection, reading cache, chapter-tap behaviour, library, browse, downloads.

Tap a chapter to **read online** (default). Long-press a chapter for:

- **Read online** — stream pages.
- **Open in reader** — fetch into the reading cache and open in KOReader's reader.
- **Keep offline** — permanent CBZ download.

Downloaded files use this layout:

```text
<download folder>/<source>/<manga>/<chapter>.cbz
```

Cached reader chapters live under KOReader's data directory in `suwayomi_chapters/` and are pruned when the cache limit is exceeded.

## References & Related Projects

| Project | Role |
| --- | --- |
| [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) | Self-hosted manga server this plugin talks to |
| [KOReader](https://github.com/koreader/koreader) | E-reader app that loads this plugin |
| [LK4D4/suwayomi.koplugin](https://github.com/LK4D4/suwayomi.koplugin) | Upstream Suwayomi KOReader client this fork builds on |
| [Catalyst](https://github.com/just-for-death/catalyst) | Companion Suwayomi client for iOS / Android by the same author |
| [koreader-komga](https://github.com/akamuraasai/koreader-komga) | Komga KOReader plugin — inspiration for bulk download and reader chapter navigation patterns |
| [rakuyomi](https://github.com/tachibana-shin/rakuyomi) | Manga downloader / reader for KOReader — reference for bulk fetch UX |

## Current Limits

Some sources search quickly, some time out, and some expose incomplete metadata. Online streaming still downloads each page on the device over the network; a page that is not yet prefetched may pause briefly on slow Wi‑Fi. The plugin does not edit source preferences or manage Suwayomi's server-side download queue.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Plugin does not appear | Folder must be named `suwayomi.koplugin`; restart KOReader after install. |
| Cannot connect | Check server URL from the device, Basic Auth credentials, and whether Suwayomi is running. |
| Source is missing | Install or update the source from **Browse**; also check **Show NSFW sources** in Browse settings. |
| Search times out | Try a source-specific Popular or Latest list, or retry with a narrower search term. |
| Chapter will not download | Open **Downloads** to inspect failed jobs, then retry or clear the failed entry. |
| Tap says downloading / hangs | Prefer **Read online** (default tap). **Open in reader** fetches the whole CBZ first; progress shows on the chapter row. |

## Credits

- Original plugin: [LK4D4/suwayomi.koplugin](https://github.com/LK4D4/suwayomi.koplugin)
- Server: [Suwayomi](https://github.com/Suwayomi)
- Reader host: [KOReader](https://github.com/koreader/koreader)

## License

No formal license file was present on the upstream project at the time of this fork. Treat this as source available for personal use unless / until a license is added. If you are the upstream author and prefer a specific license here, open an issue or PR.
