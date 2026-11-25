# Tidal broker: small HTTP server the watch app talks to during sync.
# Endpoints:
#   GET /search?q=...                 -> JSON [{id, title, artist, album, duration_s}]
#   GET /track/<id>/stream            -> direct 302 to Tidal's CDN url for an AAC m4a
#                                        (the watch requests the CDN url directly;
#                                         the 302 saves the watch from re-parsing manifests)
#   GET /track/<id>/info              -> JSON {id, title, artist, album, duration_s, bytes}
#   GET /health                       -> {"ok": true}
#
# Token handling: reads broker/credentials.json, refreshes when expired (14400 s
# confirmed from Tidal's token response). Single-threaded; fine for one watch.

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote
from urllib.request import Request as UrlRequest, urlopen
from urllib.error import HTTPError, URLError
from pathlib import Path

from tidal_auth import get_access_token, CREDENTIALS, load_credentials  # reuse our auth module

TOKEN_LOCK = threading.Lock()
_TOKEN_EXPIRE_AT = [0.0]


def tidal_api(path, params, token):
    req = UrlRequest(
        f"https://api.tidal.com/v1{path}?{params}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urlopen(req, timeout=30) as res:
        return json.loads(res.read())


def stream_url_for(track_id, token):
    # LOW/HIGH are the DRM-free AAC flavors; LOSSLESS/HI_RES unusable on Fenix 8
    info = tidal_api(
        f"/tracks/{track_id}/playbackinfopostpaywall",
        f"audioquality=HIGH&playbackmode=STREAM&assetpresentation=FULL&immersiveaudio=false",
        token,
    )
    import base64
    manifest = json.loads(base64.b64decode(info["manifest"]))
    if manifest.get("encryptionType") != "NONE":
        raise RuntimeError(f"track {track_id} returned encrypted manifest, unusable")
    return manifest["urls"][-1]


def track_summary(item):
    return {
        "id": item["id"],
        "title": item.get("title"),
        "artist": "; ".join(a["name"] for a in item.get("artists", [])),
        "album": (item.get("album") or {}).get("title"),
        "duration_s": item.get("duration"),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}")

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        route = url.path
        q = parse_qs(url.query)
        try:
            if route == "/health":
                return self.send_json({"ok": True})

            with TOKEN_LOCK:
                token = get_access_token()

            if route == "/pair":
                creds = load_credentials()
                if not creds:
                    return self.send_json({"error": "no credentials on broker"}, 500)
                return self.send_json({
                    "access_token": creds["access_token"],
                    "refresh_token": creds["refresh_token"],
                })

            if route == "/search":
                query = q.get("q", [""])[0]
                if not query:
                    return self.send_json({"error": "missing q"}, 400)
                res = tidal_api(
                    "/search",
                    f"query={quote(query)}&limit=10&countryCode=US",
                    token,
                )
                tracks = [track_summary(t) for t in res.get("tracks", {}).get("items", [])]
                albums = [
                    {"id": a["id"], "title": a.get("title"), "artist": "; ".join(x["name"] for x in a.get("artists", [])), "num_tracks": a.get("numberOfTracks")}
                    for a in res.get("albums", {}).get("items", [])
                ]
                return self.send_json({"tracks": tracks, "albums": albums})

            if route.startswith("/album/") and route.endswith("/tracks"):
                album_id = int(route.split("/")[2])
                # tidal wraps each item in {"item": {...}, "type": "track"}
                res = tidal_api(f"/albums/{album_id}/items", f"countryCode=US&limit=50&offset=0", token)
                items = []
                for entry in res.get("items", []):
                    item = entry.get("item", entry)
                    if entry.get("type") not in ("track", None):
                        continue
                    items.append(track_summary(item))
                return self.send_json({"items": items})

            if route.startswith("/track/") and route.endswith("/info"):
                track_id = int(route.split("/")[2])
                res = tidal_api(f"/tracks/{track_id}", f"countryCode=US", token)
                return self.send_json(track_summary(res))

            if route.startswith("/track/") and route.endswith("/stream"):
                track_id = int(route.split("/")[2])
                cdn = stream_url_for(track_id, token)
                if q.get("proxy", ["0"])[0] == "1":
                    # watch-side fallback: stream the bytes ourselves instead of 302
                    with urlopen(cdn, timeout=120) as audio:
                        self.send_response(200)
                        self.send_header("content-type", "audio/mp4")
                        self.send_header("content-length", str(audio.length if audio.length else -1))
                        self.end_headers()
                        while True:
                            chunk = audio.read(1 << 16)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                    return
                # otherwise 302: the player fetches the CDN url directly
                self.send_response(302)
                self.send_header("location", cdn)
                self.end_headers()
                return

            return self.send_json({"error": "not found"}, 404)
        except (HTTPError, URLError) as e:
            return self.send_json({"error": f"tidal: {e}"}, 502)
        except Exception as e:
            return self.send_json({"error": str(e)}, 500)


def main():
    port = int(__import__("os").environ.get("BROKER_PORT", "8734"))
    print(f"broker on http://0.0.0.0:{port} (credentials: {CREDENTIALS})")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
