# Finamp+ status (started and last updated 2026-11-09)

Working notes for this fork. This repository is public: no server addresses, account IDs, keys or log contents here.

## Where things are

- Branch `library-search`, pushed to the `fork` remote (`baslawson/finamp`). `origin` is upstream `jmshrv/finamp`.
- Latest release: **1.6.102** (`aca28657`), built from `16b4b151`.
- Release steps:
  1. Commit the change. Its message body becomes the release notes, so write it for users.
  2. Commit the `pubspec.yaml` version bump as `Release X.Y.Z`, directly after it.
  3. Tag `vX.Y.Z` and push the branch and the tag. `release-plus.yml` tests, builds the signed APKs and publishes.
- Never leave a notes-only commit directly before a `Release` commit: its message would become the release notes.
- Flutter is at `~/flutter/bin` on the devbox. `flutter test` takes about 2 minutes (1,477 tests at 1.6.102).

## Servers

- **Jellyfin server** (the `jellyfin` entry in AgentReclaim's settings): runs Jellyfin 12.4.0 and the `finamp-analyzer` and `finamp-karaoke` containers.
- Logs uploaded from the phone are on that server, under the analyzer's `data/hub/reports/<jellyfin-user-id>/`. Each is a `logs-*.zip`. `Logs/` in this folder only holds old manual copies from October and isn't tracked.
- The **home** server in AgentReclaim's settings is the trading server and has nothing of Finamp's on it.
- The analyzer's Jellyfin API key has no signed-in user. Jellyfin refuses it for anything needing one, such as moving a song within a playlist. It only accepts the `Authorization: MediaBrowser Token="..."` header.

### Server changes (2026-11-10)

- **Unfinished downloads hidden from Jellyfin.** qBittorrent now adds `.!qB` to files that aren't complete, so Jellyfin skips them. The James Reyne download stopped at 67% with no seeders. Jellyfin couldn't read many of its files and logged about 150 errors a day. Now 44 of its 186 songs are in the library. The rest come back if the download ever finishes.
- **The VM's CPU type is `host`** (it was the default QEMU CPU). It now has AVX, AVX2 and AVX-512, which speeds up loudness measurement, the analyzer and karaoke. Changing it in Proxmox needs a Shutdown and Start from Proxmox; a reboot from inside the VM isn't enough. No GPU (Dell R640, Xeon Gold 6140 without built-in graphics), so video conversion runs on the CPU.
- **The VM has 12 cores** (it had 6).
- **Video conversion:** 4K HDR to SDR tone-mapping, tested with Jellyfin's own settings, runs at 1.4× on 12 cores (0.98× on 6). It only uses about 8 of the 12, so more cores would add little. One 4K HDR stream plays smoothly; two at once would stutter, so direct play on a device that handles HEVC and HDR is the fix for that. Music conversion to Opus runs at 30–70×.
- **Updated and restarted** onto the new kernel. Every container came back by itself. The analyzer logs "Library scan unavailable" for about a minute while Jellyfin starts, then carries on.
- **Docker cleanup** freed about 10 GB: old untagged images, older rollback images, and build cache older than 7 days. The rollback images kept are `finamp-analyzer:before-linkstop` and `finamp-karaoke:before-linkstop`.

- **Jellyfin pinned** to `lscr.io/linuxserver/jellyfin:12.4ubu2604-ls58` (was `latest`), in its Portainer stack. Done because the 1.6.101 playlist skip relied on how Jellyfin 12.4 sets a playlist's Etag. Since 1.6.102 Finamp checks that itself after any Jellyfin upgrade, so the pin is no longer needed for Finamp; it can go to `version-12.4ubu2604` or back to `latest`. The pin also stops operating-system updates inside the image: bump the `-lsNN` number by hand now and then. `version-12.4ubu2604` would stay on 12.4 and still get them.

Not done yet:

- Tugtainer's settings haven't been checked. They're in its main instance, which needs a login. Since 7 November its agent has only listed containers and inspected images, never updated one. With Jellyfin pinned, this only matters for the other containers.
- The lyrics plugin gets many rate-limit replies (HTTP 429) from LRCLIB. They're harmless.
- One add-to-playlist failed on 8 November with a database error (`FOREIGN KEY constraint failed`). It hasn't happened again.

## 1.6.101: automatic resyncs skip unchanged playlists

An automatic resync used to send one request per playlist (about 297 requests, up to 166 s, at most every 12 hours). About 249 of those playlists are info-only (the song list is kept, the songs aren't downloaded). Those are now left out when unchanged. That also saves about 3,177 song syncs that followed from them.

A playlist is left out only when all of these hold (`_unchangedPlaylistTracks` and `playlistUnchanged` in `downloads_service_backend.dart`):

- It's info-only, and this is an automatic resync with quick sync on.
- Its Etag and its details (`mostlyEqual`) match what's stored, and the server's track count matches the stored links.
- The Etag has been confirmed reliable on the server's Jellyfin version (below).
- Its song list has been stored at least once.
- Neither it nor a direct child (song, cover) has failed.

`DownloadsService.skipUnchangedPlaylists` turns this on just before an automatic resync. It stays off for the weekly full check (`fullPlaylistCheckInterval`) and when other sync work is running or left over. It's cleared when the user starts a sync and when the run ends.

### 1.6.102: the skip checks itself

The skip relies on Jellyfin giving a playlist a new Etag whenever its tracks change. Finamp now checks that itself, so it doesn't depend on Jellyfin staying at 12.4 (`etagPlan`, `etagCheckResult` and `recordEtagCheck` in `downloads_service.dart`; `_checkPlaylistEtag` in `downloads_service_backend.dart`):

- Before each automatic resync it reads Jellyfin's version (`/System/Info/Public`). On a cold start that happens with the sync, 10 s after the app opens, so opening isn't delayed.
- The first resync on a version it hasn't checked, or after an upgrade, is a full check. So is any resync where the version can't be read.
- During each full check, every playlist that would have been left out has its fresh track list compared with the stored one. Different tracks count against the Etag only if the playlist, asked for again, still has the same Etag; a new one means it was edited during the check.
- One playlist changed without a new Etag: the log says `Playlist skip turned off: …` (stored as `off|<version>` under `downloadsPlaylistEtagCheck`), and nothing is left out until Jellyfin's version changes.
- All the same, at least one compared, and the check finished (no sync left queued, every candidate compared): the Etag is confirmed (`ok|<version>`), and playlists are left out until the next full check.
- Anything less (offline partway, syncing paused, failures, nothing compared): the stored result is cleared and the log says `Playlist skip not confirmed …`, so the next automatic resync checks everything again.
- Log lines to look for: `Playlist skip checked on Jellyfin <version>: …` or `Playlist skip turned off: …`, and `<playlist> changed without a new etag.` for each mismatch.
- Known limit: reordering a playlist counts as changed. If Jellyfin didn't give it a new Etag (moving wasn't tested live), that turns the skip off, which is right, since a left-out playlist would keep its old order.
- Known limit: a library rescan that gives a song a new ID without a new playlist Etag also counts as a mismatch. That turns the skip off until the next Jellyfin version: safe, but it saves nothing meanwhile.
- After installing it, the first automatic resync is a full check, since no version has been checked yet.

Reviews: Codex and an independent agent (standing in for claude-checker, which isn't on the devbox) reviewed it, then rechecked three times. They found 8 bugs and 3 concerns: an interrupted or empty check recording `ok`; an edit during the check counting as a miss; a 5 s startup delay; a gap at the end of a run; a resync lost if the app closed within 10 s; a joined run confirming or dropping results; a user sync in the first 10 s going unnoticed. All were fixed, and both reviewers confirmed the final version with nothing open.

To check after 1.6.102: in an uploaded log, the first automatic resync should end with `Playlist skip checked on Jellyfin 12.4.0: …`, and later ones should show `Left out N unchanged playlists.` again.

Evidence for relying on the Etag:

- Live test on the Jellyfin server with a throwaway playlist, since deleted: the Etag stayed the same with no edit and changed on add and on remove.
- Jellyfin's `master` source: the Etag is a hash of `DateLastSaved`, and add, remove and move all go through `UpdatePlaylistInternal`.

Also in 1.6.101: a burst of `/Playlists/{id}/Items` requests logs the first three in full, then one summary line (`RequestBurst` in `chopper_aggregate_logger.dart`). Failures always log in full.

Reviews: Codex and an independent agent reviewed it and rechecked the fixes. All confirmed bugs were fixed. The final fix (`mayLeaveOutPlaylists`) is what both suggested, and it has no review pass of its own.

### Known limits

- Moving a song within a playlist wasn't tested live, only read in the source.
- The source read was `master`; the `v12.4.0` tag wasn't available.
- `_unchangedPlaylistTracks` (was `_canSkipUnchangedPlaylist`), `_checkPlaylistEtag` and the recording in `executeSyncs` have no unit test, since they need the on-device database. Their decisions are tested through `playlistUnchanged`, `mayLeaveOutPlaylists`, `etagPlan`, `etagCheckResult` and `sameTracks`.
- A failed cover on an info-only song is retried only by the weekly check or a manual sync.
- If the user starts a sync during an automatic one, playlists already left out in that run stay left out until the next check.
- A playlist opened during a resync can show only in the summary count.
- A playlist with the same song twice is never left out, because its links are fewer than its track count. Safe, but saves nothing.
- A song swapped on the server with no change to the playlist's Etag or count waits for the weekly check.

## To check next

- On 1.6.102, the first automatic resync is a full check that confirms the Etag: look for `Playlist skip checked on Jellyfin 12.4.0: …` (or `Playlist skip turned off: …` / `not confirmed`). From the second one on (at least 12 hours later), look for `Left out N unchanged playlists.` N should be near 249, and `/Playlists/{id}/Items` requests should drop to about 48.
- If N is near 0, find which condition fails. The most likely causes are the Etag not confirmed yet, `mostlyEqual` differing, or the stored links not matching the track count.
- Checked 2026-11-10: the 9 November upload covers about 22 hours on 1.6.101 (9 November 06:28 to 10 November 04:52, phone time) and has no automatic resync in it, so there's no `Left out N` line yet. No 1.6.101 log with a resync is needed any more: the check above replaces it on 1.6.102.

## What the logs showed (reviewed 2026-11-09)

Reviewed: the six October uploads in `Logs/` (24–28 October, up to 1.6.71) and the two latest uploads (28 October to 9 November, up to 1.6.100). 1.6.100 had no errors and one harmless warning, over only 4 plays.

1.6.101 (checked 2026-11-10, same upload): no errors and no failed requests. Three warnings, all normal: two `_buildQueueFromNativePlayerQueue` ignores and one WebSocket reconnect right after the update installed. Crossfade did 8 transitions with no underruns.

Already fixed, or not seen again. No need to re-investigate unless they come back:

| Problem | Status |
|---|---|
| `POST /Playlists` 400 on `IsPublic` | Fixed: an empty value is left out. Last seen 28 October |
| Play On retrying without a network | Fixed in 1.6.92 (`waitForNetwork`). Last seen 2 November |
| `MissingPluginException` on background engines | `BackgroundChannels.kt` registers them. Last seen 31 October |
| Screen wakelock `PlatformException` | Goes through `screen_wakelock.dart` now. Seen once, 5 November |
| Songs skipped on HTTP 500 and 404 | None since 29 October. Cause never established |
| `bool`/`double?` cast in `ScrollPosition.restoreScrollOffset` | Not seen since 26 October (115 times in one hour). **Cause never found**, so it may return |
| Null check in `scrollToKey` (`queue_list.dart:85`) | Not seen since 27 October. Code not rechecked |

Normal, no change needed:

- LRCLIB 502/503 failures come from its own service, and the app already retries them.
- `Ignoring call to _buildQueueFromNativePlayerQueue` is the app deliberately ignoring a call during a queue swap.
- Crossfade is healthy: 2 underruns in 1,283 readings.
