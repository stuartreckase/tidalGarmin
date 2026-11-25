<p align="center"><img src="docs/logo.svg" width="160" alt="tidalGarmin logo"></p>

# tidalGarmin

Unofficial Tidal client for Garmin Fenix 8 Solar 47mm (`fenix8solar47mm`).
Connect IQ audio content provider: syncs DRM-free AAC (≤320 kbps) from Tidal
over Wi-Fi into the watch's encrypted media cache and plays it in the native
media player. Not affiliated with Tidal or Garmin.

## Features

- Tidal OAuth device-code login on the watch (enter code at `link.tidal.com`)
- Browse own + favourited playlists (newest first, 10 per page)
- Multiple playlists on the watch; play one or all; offline "On watch" menu
- Sync direct from Tidal API/CDN, deduplicated across playlists
- Shuffle, repeat (off → all → one); bottom-left button = next track
- Storage guards: free-space check per track, 200 tracks/playlist, 400 total;
  tracks are deleted only when no synced playlist references them
- Persistent on-watch log (Show log, UP/DOWN to scroll)

## Requirements

- Connect IQ SDK 9.3.0 + `fenix8solar47mm` device pack (SDK Manager)
- Java (for `monkeyc`)
- Developer key: RSA 4096, PKCS#8 DER
  ```sh
  openssl genrsa -out developer_key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem \
    -out developer_key.der -nocrypt
  ```
- Tidal subscription; watch Wi-Fi configured

## Build

`watchapp/build.sh` expects the SDK and key at the paths set in its `SDKM` /
`KEY` variables (default: `~/Library/Application Support/Garmin/ConnectIQ/`).

```sh
cd watchapp
./build.sh        # -> bin/tidal.prg
./build.sh -r     # build + run in a running simulator
```

The build must finish with no `Statement is not reachable` warnings (see Notes).

## Install (sideload)

1. Connect the watch over USB (macOS: MTP, e.g. via Finder/Android File Transfer).
2. Copy `watchapp/bin/tidal.prg` to `GARMIN/APPS/`.
3. Reboot the watch. Replacing an existing build also requires a reboot.

## Use

Music → Tidal → app menu:

| Item | Action |
|---|---|
| Play | play the selected playlist |
| On watch | synced playlists → Play / Remove from watch; "All playlists" |
| Browse playlists | Tidal playlists → select to add + sync |
| Sync now | re-sync every playlist on the watch |
| Storage | media cache MB used / capacity |
| Show log | diagnostics (`SYNC:`, `PI`, `DL`, `OK`, `ERR`, `ITER:`) |
| Login to Tidal | device-code login |
| Clear cache | wipe media cache + mappings (reopen app after) |

## Layout

```
watchapp/
  manifest.xml            app type audio-content-provider-app
  source/TidalProvider.mc single source file (by design)
  resources/              strings, icon, BrokerURL property
broker/                   legacy Python (stdlib) helper, not needed for normal use
  tidal_auth.py           device-code login -> credentials.json
  broker.py               HTTP server: /pair /search /album/<id>/tracks /track/<id>/{info,stream}
```

## How it works

Sync (only inside `SyncDelegate.onStartSync`, gated by a persisted
`syncRequest` flag):

1. Refresh token (`auth.tidal.com/v1/oauth2/token`; yields `user_id`, country).
2. Per playlist: `GET /v1/playlists/{uuid}/items`, `limit=3`, paged; page
   size shrinks on `-402` (response too large).
3. Prune tracks no playlist references (`Media.deleteCachedItem` on stored refs).
4. Per track: `GET /v1/tracks/{id}/playbackinfopostpaywall?audioquality=HIGH`
   → base64 manifest → require `encryptionType NONE` → CDN URL →
   `makeWebRequest` with `HTTP_RESPONSE_CONTENT_TYPE_AUDIO`, `ENCODING_M4A`.
5. Store `DL_<trackId>` = ContentRef id, `MT_<trackId>` = metadata.
6. `notifySyncComplete` exactly once; 3 consecutive network errors abort.

Playback: `Media.ContentIterator` built from stored mappings (never from
`Media.getContentRefIter`), metadata applied via `Content.setMetadata`.

## Notes / pitfalls

- `LOSSLESS` (FLAC) and `HI_RES` (Widevine) are unusable on the watch; AAC only.
- Dolby Atmos tracks return E-AC-3 (`eac3`) unless the playback-info request
  includes `immersiveaudio=false`; E-AC-3 fails on the watch with `-1005`.
- VM errors (`Unexpected Type Error`, `Failed invoking <symbol>`) bypass
  try/catch. `Media.getContentRefIter().next()` throws them on an empty or
  just-reset cache, so the sync never enumerates the cache.
- The AUDIO callback's declared `data` type omits `Media.ContentRef`; a direct
  `instanceof` check is flagged unreachable and dropped at `-O2`. Use an
  untyped helper.
- Store ContentRef ids raw (`getId()` may be a Number), not `toString()`.
- Audio downloads outside sync mode fail with `-1002`.
- `System.exit()` is a no-op in the config view; reopen the app manually.
- Simulator: launch the SDK's own `ConnectIQ.app` binary, not a symlink copy.

## Credits

Tidal auth flow and client credentials from
[tiddl](https://github.com/oskvr37/tiddl) (GPLv3).
