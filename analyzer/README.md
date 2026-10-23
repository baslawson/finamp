# Finamp+ analyzer

A small service that runs next to Jellyfin on your Linux server. It listens to every song in your library once and then gives Finamp+:

- **Search by vibe**: describe a sound ("dreamy synths with a slow beat") and get the tracks that sound like it. This uses [CLAP](https://huggingface.co/laion/clap-htsat-unfused) audio-text embeddings, so it matches the actual sound, not the tags.
- **DJ transitions**: tempo, key and loudness per track. Finamp+ times its fades to each song's tempo and orders AI DJ and vibe mixes so keys (Camelot wheel) and tempos flow into each other.
- **What's this song?**: hold your phone near music that's playing, and Finamp+ finds the song in your library. This uses [Chromaprint](https://acoustid.org/chromaprint) fingerprints.
- **Volume normalization**: full-song integrated LUFS and oversampled true peaks, plus complete-album measurements with a shared R128 gate. Finamp+ caches these for offline playback.
- **Karaoke**: prepare AI instrumentals and guide-vocal mixes on demand. A separate CPU worker processes one song at a time, caches lossless FLAC versions, and leaves the music mounts read-only.

Everything runs on your own server. Models are downloaded once; your audio stays on the server. The optional karaoke worker also downloads its pinned UVR MDX model on first use.

## Setup

1. Create a Jellyfin API key: **Dashboard → API Keys → +**.
2. Copy this folder to your server and edit `docker-compose.yml`:
   - `JELLYFIN_URL`: how the container reaches Jellyfin, for example `http://192.168.1.10:8096`.
   - `JELLYFIN_API_KEY`: the key from step 1.
   - `ANALYZER_TOKEN`: any long random secret, for example the output of `openssl rand -hex 24`. The analyzer refuses every request while this is empty or still the example value.
   - The music volume: mount the same folder Jellyfin uses, read-only. If Jellyfin sees it under a different path (for example `/media/music` inside Jellyfin's container), set `PATH_MAP: /media/music=/music`.
3. Start it with `docker compose up -d --build`.
4. In Finamp+, go to **Settings → Finamp+ analyzer**, enter `http://<server>:8787` and the token, then tap **Save and test**.

The first scan takes a while: roughly 1 to 3 seconds per song on a modern CPU. Finamp+ shows the progress. The analyzer rescans every 6 hours (`RESCAN_HOURS`) and only analyzes new or changed files.

Loudness analysis reads the entire recording and then each complete album; allow longer than the excerpt-based AI scan. It decodes to 48 kHz stereo consistently for track and album playback. Albums are measured as a continuous program, never by averaging track LUFS. Files that change, disappear, fail decoding, or contain silence do not retain a usable stale track measurement. Incomplete albums do not receive an album measurement.

For a small server that only needs normalization, set the Docker build argument `ADVANCED_ANALYSIS: "false"`. This omits the optional PyTorch/CLAP dependencies and AI indexing; normalization remains available. The default build keeps all existing analyzer features. Loudness data lives in a separate `loudness.db`, preserving existing `analysis.db` data. Mount music read-only and keep API keys and the analyzer token outside source control; `.dockerignore` excludes local secrets and data from the build context.

In the app, use **Settings > Volume normalization** for Off, Quiet (-19 LUFS), Normal (-14 LUFS), and Loud (-11 LUFS). Automatic uses album gain for an album played in order and track gain for mixes, playlists, and shuffles. Quiet/Normal cap boosts at measured peak headroom. The Android PCM limiter uses four-phase oversampled peak detection, a -1 dB ceiling with an interpolation reserve, 5 ms lookahead attack and 100 ms release. Each crossfade player receives its own gain before mixing; limiting occurs after the float mix. Positive device EQ boosts reserve additional headroom. Normalization suspends audio offload because offload bypasses PCM processors.

The app prepares the next six songs before fetching the rest of a queue in small batches. Once a song's gain is in use it stays fixed for that playback, including both crossfade decoders; late measurements apply on a subsequent playback. Explicit normalization and EQ changes still take effect, with gain changes smoothed. Completed downloads retain a separate measurement snapshot, so replacing the server's original does not change an already downloaded copy. Pending download measurements are filled when analysis becomes available, and deleting the download removes its snapshot. Open a song's menu and choose **Volume normalization** to see the applied adjustment, album/track mode, or whether analysis is pending. Details distinguish the current playback from a preview for another song.

The previous Android loudness enhancer and base gain controls are replaced. Existing On/Off preferences are preserved. Without measurements, Jellyfin gain is used for attenuation only because its reference and peak headroom are unknown; Quiet/Normal reserve at least 1 dB of sample headroom. Until an album measurement arrives, a common album fallback preserves the album's balance. Android supports boosts and limiting; other platforms currently use attenuation only.

To reach the analyzer away from home, put it behind the same reverse proxy as Jellyfin (with HTTPS), or use a VPN. Behind a proxy, set `FORWARDED_ALLOW_IPS` to the proxy's address so TV pairing limits apply per device. The hub's browser pages accept the host from `X-Forwarded-Host`; if your proxy doesn't send it, set `PUBLIC_URL` to the address you open, for example `https://music.example.com`.

### Running the containers

- **User:** both containers run as root unless you set `PUID` and `PGID`, for example to the user that owns your music. They then give that user the `data` folder at startup and drop root. That user needs to be able to read the music and write to the Jellyfin backup folder.
- **Health checks:** Docker checks each container through `/healthz`, which needs no token and reveals nothing about the library.
- **Shutting down:** `docker compose down` allows 30 seconds for a measurement, broadcast or backup to finish.
- **Logs:** each container keeps at most 30 MB of logs. The request log shows routes without the radio, TV audio and backup tickets.

## Karaoke

The compose example includes a separate worker with a 1.5 CPU quota and a 3 GB memory limit. It uses CPU-only PyTorch 2.5.1 and Audio Separator 0.30.2, isolated from the analyzer's NumPy environment. Music mounts and `PATH_MAP` must match the analyzer. Only the analyzer's port needs to be exposed; `KARAOKE_URL` forwards authenticated `/karaoke` requests to the worker on the Docker network.

In Finamp+, open the current song's menu > **Karaoke**, or **Lyrics > microphone**. Tap **Prepare karaoke**, wait for the background job, then Play. Other songs have **Prepare karaoke** in their track menu, which queues preparation without changing playback. Guide vocals are available at 0, 25, 50, 75 and 100 percent. Changing the vocal level reloads the prepared mix at the same position. **Save this mix offline** retains that vocal level and its measured loudness; downloaded lyrics are remembered too. Find downloaded songs under Settings > Saved karaoke, even if the original song is not downloaded. Other vocal levels require downloading their own mixes. Main-player controls, seeking and lyrics use the original song's identity; crossfades and DJ introductions are suspended during karaoke. Leaving karaoke restores the original audio at the same position when opened from a regular music queue. A Saved karaoke queue continues to use its downloaded instrumental.

The Android stereo-centre vocal-removal effect has been removed. The spectrum visualizer only observes the samples. Karaoke now uses actual server-separated audio on every supported playback platform.

**Settings > Karaoke dashboard** lists server jobs with Queued, Processing, Ready, and Failed filters. It refreshes active jobs, loads additional pages, and resolves song details through the signed-in Jellyfin account. Ready mixes can be played or saved offline; failed jobs can be retried. The existing Saved karaoke screen continues to list this device's downloads. Both the analyzer and worker need the catalogue endpoint for this screen.

Use a song's three-dot menu in **Saved karaoke > Delete from phone** to remove all its downloaded karaoke vocal levels and lyrics. **Karaoke dashboard > Delete server mixes** removes the prepared mixes or cancels a queued preparation; processing jobs must finish first. Both actions ask for confirmation. Phone and server copies are independent, and neither action deletes the original music file.

In the karaoke player's **Practice** controls, mark A and B at least one second apart to loop a section. Practice speed keeps the original pitch and is restored when leaving or changing songs. Optionally reduce guide vocals by one available level after each loop.

The worker decodes to disk and separates overlapping 60-second sections, blending their two-second overlaps without changing the timeline. It releases model memory when each song finishes. Cache entries depend on the source path, modification time, file size, model and pipeline version. Interrupted jobs can be retried, and changed originals invalidate old server results. The queue holds at most 20 songs; individual songs must be shorter than 20 minutes. The server hub can queue a limited overnight batch of selected songs and favourites. Separated audio can contain artifacts; assess a few recordings before queuing many songs. Cache lives under `data/karaoke`.

`GET /karaoke/{jellyfin-id}` reports `missing`, `queued`, `processing`, `ready` or `failed`. `POST` on the same path queues or retries preparation idempotently. `GET /karaoke/{id}/audio?guide=0&revision=<revision>` serves a prepared FLAC with HTTP range support. Every request requires the existing analyzer token in `X-Api-Key`; tokens are never put in audio URLs. Each ready response contains its mixes' full-song LUFS, true peak, byte count and preparation time.

Run `python -m unittest -v test_karaoke test_karaoke_worker` in the karaoke image for queue, authentication, cache invalidation, chunk alignment and guide-vocal regressions.

## API

All endpoints except `/healthz` need the header `X-Api-Key: <ANALYZER_TOKEN>`.

| Endpoint | Description |
| --- | --- |
| `GET /karaoke?offset=0&limit=50&state=ready` | Paginated karaoke jobs, with optional queued/processing/ready/failed filtering; limit is capped at 100. Song IDs are resolved through the app's Jellyfin account before display. |
| `DELETE /karaoke/{id}?revision=<revision>` | Removes that job and its prepared cache. Processing jobs or a changed revision return 409. Shared caches remain until the last referring job is removed. Original music and the worker's models are never deleted. |
| `GET /status` | `{analyzed, failed, total, scanning}` |
| `GET /vibe?q=<text>&limit=50` | Tracks that sound like the text, best first: `[{id, score}]` |
| `POST /analysis` `{"ids": [...]}` | Tempo, key, Camelot key and loudness per Jellyfin track id |
| `POST /loudness` `{"ids": [...]}` | Full-program `{lufs, truePeak, albumLufs, albumTruePeak, revision, albumRevision, version}` per measured Jellyfin track id; missing or silent tracks are omitted |
| `POST /identify` (body: audio file, at most 4 MB) | `{id, confidence}` for the library track in a short recording, or `{id: null}` |
| `GET /similar?id=<id>&limit=50` | Tracks that sound like that track, most alike first: `[{id, score}]` |
| `GET /health` | Library check-up: undecodable, cut-off and duplicate recordings, long silent endings and missing tags |
| `GET /healthz` | `{ok: true}` without a token, for container health checks |

Without `JELLYFIN_URL`, the analyzer indexes every audio file under `/music` and uses a hash of each path as the id. That mode is handy for testing.

`GET /status` also includes a `loudness` object with `measured`, `albums`, `failed`, `missing`, `total`, and `scanning`. Run meter/cache regressions with `python -m unittest -v test_loudness` in the analyzer environment.

## Server hub

Open **Finamp > Settings > Server hub**. The app uses the configured analyzer address and the current Jellyfin account. **Open server controls** launches a one-hour browser session. Administrator accounts manage server-wide features; each account has its own rooms, stations, preferences, listening history and saved queue. Access tokens remain in HTTP headers. Browser links contain short-lived, signed capabilities in URL fragments, removed from the address bar on load. Only the hub's scoped audio/download tickets appear in media URLs.

* **TV karaoke:** create a room, open `/hub/tv/` on a TV/laptop, then enter its six-digit code or scan the app's QR code. Open **Phone remote** to choose songs, pause, seek, change guide vocals or move to the next request. Guests scan the TV QR code to request prepared songs. The code is single-use and lasts ten minutes; rooms/links last six hours. Browser audio needs one **Start TV audio** tap. A processing song waits for its prepared audio without advancing the playback clock. Source audio stays read-only.
* **Lyrics:** install the Jellyfin Lyrics plugin from its official repository, enable artist/duration matching and keep `SaveLyricsWithMedia` disabled on read-only libraries. The dashboard starts its `DLLyrics` task; this server uses 03:45 Australia/Brisbane and a 250-song cap. Selecting a TV song also searches the installed Jellyfin lyric providers, accepting only synced lyrics with the same title/artist and duration within ten seconds. Existing timed lyrics are kept. Some recordings have no matching timed lyrics.
* **Radio:** switch on the station and copy its listening link. The server maintains a continuous 160 kbit/s stereo MP3 stream while phones are disconnected. Two minutes after the last listener leaves, it stops decoding and reading music until someone tunes in again, starting with the station introduction. The schedule defaults to morning favourites at 07:00, discovery at 12:00, and calmer songs at 18:00. Program changes wait for a song to finish. Adjacent artists and recent songs are avoided when alternatives exist. Current full-song loudness measurements target -14 LUFS with measured peak headroom. **Create a station introduction** in Finamp records the current DJ voice once; the server reuses it at program changes/every five songs. Introductions can be removed in browser controls. Up to eight simultaneous listeners are supported.
* **Overnight:** defaults to 02:00–06:00, at most three new songs each night, one separation job at a time. Chosen songs and favourites skip already prepared/queued songs. Cache defaults to 20 GB/30 days of inactivity. Chosen songs, favourites and active-room queues are protected, so protected mixes may exceed the target. Cleanup removes eligible server mixes and associated browser transcodes, preserving music originals and phone downloads.
* **Audio health:** overnight scans fully decode up to 100 new/changed recordings and distinguish failed decoding from decoder warnings even when FFmpeg exits successfully. Enable **Skip failed recordings in generated mixes** per account; warning exclusion is a separate option. Changed files invalidate exclusions. The app checks generated queue starts and refills; manual album/song playback remains available. Server outages retain normal playback.
* **Across devices:** background sync runs every 30 seconds while Finamp is running. Saved stations merge per ID; local edits/deletions are rebased over concurrent server edits. Listening history contains IDs/times only. **Resume here** explicitly restores the saved order and position on another device; remote snapshots never automatically interrupt playback. A stale paused/still-playing phone cannot overwrite another device's saved queue without a new playback action. Each device can disable sync.
* **Backups:** mount Jellyfin's dedicated native backup folder into the analyzer at `/jellyfin-backups`; the complete Jellyfin config must not be mounted writable. Requires Jellyfin's `/Backup/Create` API (verified on Jellyfin 12). Daily default is 03:15, retaining seven hub archives. Each archive includes the native Jellyfin database/config/plugin export, consistent SQLite snapshots of Finamp data, analyzer settings and the hub signing secret. Original audio, models, and rebuildable karaoke/browser caches are excluded. ZIP integrity, JSON database exports, SHA-256 inventory, and restored SQLite databases are checked in an isolated temporary directory. These archives contain private credentials: use the authenticated dashboard download and store copies privately. `HUB_REMOVE_NATIVE_BACKUP=true` removes only the exact native ZIP just created for a successfully verified hub bundle; pre-existing Jellyfin backups are preserved. Create/verify a backup before updating these services.

Backups on the same server protect against accidental changes, not disk loss. Copy verified archives to a separate device for that protection.

### Server workload and status

Administrator accounts can open **Settings > Server hub > Open server controls > Server status** to see available memory, free working space, active players, background workers, queued jobs and reasons for waiting. Use **Refresh server status** for a fresh snapshot. A long-running job is flagged for inspection, not automatically cancelled.

The analyzer and karaoke worker share a single background-work lease in `/data/runtime`; both containers must mount the same `/data`. Analysis, loudness measurement, karaoke preparation, health checks and media/backup jobs take turns. API handlers, radio output and playback do not wait for this lease. Background analysis and hub jobs run at a lower Linux scheduling priority; the example Compose file also gives the background containers lower CPU shares.

New heavy jobs wait when playback status is unavailable, memory or disk pressure is high, or less than 2 GiB of working space remains. Karaoke requires 1.5 GiB of available memory before starting; other preparations require 256 MiB. An individual measurement or separation finishes before yielding. Health checks can yield between songs and resume from their saved position. Queued preparations retain their place while waiting.

Files that fail analysis or measurement are tried again after three days, not on every scan, and asking for them doesn't wake a scan. The vibe search model is unloaded after 30 minutes without a search or scan (`CLAP_IDLE_MINUTES`; 0 keeps it loaded) and loads again on the next search. Song recognition runs beside the other requests instead of holding them up.

Missing analysis requested by the app wakes a scan, coalesced over five minutes and limited to once per track per hour. Requested tracks, current/upcoming queues, favourites and recent listening are checked before the rest of the library. Unchanged measurements remain cached; album members keep their original order and no measurement versions or audio formulas change. Failed library scans retry with a one-to-five-minute backoff instead of waiting for the next six-hour scan.

Server requests reuse per-thread HTTP connections without retaining account cookies or credentials between requests. Identical metadata lookups share an in-flight request and a five-second cache, scoped to the account and complete query, bounded to 128 entries and 512 items. Random pools, live favourite queries and large catalogue pages bypass that cache. Request metrics report counts and recent response times, without tokens or song IDs.

### Restore

1. Keep the live services stopped while restoring. Preserve a separate copy of the current data/config first. Inspect the archive inventory with `hub_jobs.Jobs.verify_archive(path)` in the matching analyzer image; this verifies without changing live data.
2. Extract a verified archive in a private folder. Use Jellyfin's own backup restore to import `files/jellyfin.zip` into a compatible Jellyfin version. Its database is an exported set of JSON tables on Jellyfin 12, not a raw SQLite file. Do not overwrite a running Jellyfin database.
3. With analyzer/karaoke stopped, restore `analysis.db`, `loudness.db`, `karaoke/jobs.db`, and `hub/hub.db` from the corresponding hyphenated filenames under `files/`. Move aside old `-wal`/`-shm` companions; preserve ownership. Restore `hub-secret` as `hub/.capability-secret` with mode 600. Recreate the compose environment privately from `analyzer-settings.json`; music mounts must remain read-only. Set `radioEnabled` false in a restored hub before first startup if you do not want it to begin broadcasting immediately.
4. Restart Jellyfin, then analyzer/karaoke. Rebuild unavailable karaoke mixes from originals. Verify account sign-in, library access, and saved stations/queues before deleting the preserved current data.

### Regression checks

Install `requirements-test.txt` alongside the analyzer/worker dependencies, then run `python -m unittest discover -v` in an isolated environment with a temporary `/data`. The hub tests use mocked Jellyfin/worker clients and temporary files; never point tests at production data. `test_hub_browser.cjs` exercises a real deployed test room using Playwright, including playback, guide vocals and guest requests. Supply `HUB_TEST_URL`, a private `HUB_TEST_CAPS` file, `HUB_TEST_SONG`, `HUB_TEST_SECOND`, and `HUB_TEST_OUTPUT`. Close the test room afterward.

Hub API calls under `/hub/api` require both `X-Api-Key` and `X-Jellyfin-Token`, or a signed browser session. Room controls and guest requests use separate room capabilities. The main API groups are `/status`, `/settings`, `/radio`, `/rooms`, `/sync`, `/health`, `/jobs`, `/lyrics`, and `/backups`.
