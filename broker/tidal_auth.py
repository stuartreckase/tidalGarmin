# Tidal OAuth2 device-code flow, ported from oskvr37/tiddl (GPLv3).
# Gets an access+refresh token pair and stores it in credentials.json.
#
# Usage: python3 tidal_auth.py login   # run once; opens browser for approval
#        python3 tidal_auth.py check   # validate stored token, refresh if expired
#
# Env override for credentials: TIDAL_AUTH="client_id;client_secret"

import base64
import json
import sys
import time
import webbrowser
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlencode

CLIENT_ID, CLIENT_SECRET = (
    base64.b64decode(
        "NE4zbjZRMXg5NUxMNUs3cDtvS09YZkpXMzcxY1g2eGFaMFB5aGdHTkJkTkxsQlpkNEFLS1lvdWdNamlrPQ=="
        )
    .decode()
    .split(";")
)

AUTH_URL = "https://auth.tidal.com/v1/oauth2"
API_URL = "https://openapi.tidal.com/v2"
SCOPE = "r_usr+w_usr+w_sub"

CREDENTIALS = Path(__file__).parent / "credentials.json"


def post(url, data, basic_auth=None):
    headers = {"content-type": "application/x-www-form-urlencoded"}
    if basic_auth:
        import binascii
        raw = f"{basic_auth[0]}:{basic_auth[1]}".encode()
        headers["authorization"] = "Basic " + base64.b64encode(raw).decode()
    req = Request(url, urlencode(data).encode(), headers)
    with urlopen(req) as res:
        return json.loads(res.read())


def load_credentials():
    if CREDENTIALS.exists():
        return json.loads(CREDENTIALS.read_text())
    return None


def save_credentials(token):
    CREDENTIALS.write_text(json.dumps(token, indent=2))
    print(f"saved -> {CREDENTIALS}")


def login():
    # step 1: ask Tidal for a device code and a verification URL
    device = post(
        f"{AUTH_URL}/device_authorization",
        {"client_id": CLIENT_ID, "scope": SCOPE},
    )
    print(f"open: {device['verificationUriComplete']}")
    print(f"code: {device['userCode']}")
    try:
        webbrowser.open("https://" + device["verificationUriComplete"])
    except Exception:
        pass

    # step 2: poll until the user approves (or the code expires).
    # pending approval comes back as HTTP 400 with a JSON body.
    interval = device.get("interval", 2)
    deadline = time.time() + device.get("expiresIn", 180)
    while time.time() < deadline:
        try:
            token = post(
                f"{AUTH_URL}/token",
                {
                    "client_id": CLIENT_ID,
                    "device_code": device["deviceCode"],
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "scope": SCOPE,
                },
                basic_auth=(CLIENT_ID, CLIENT_SECRET),
            )
            save_credentials(token)
            return token
        except Exception as e:
            body = getattr(e, "read", lambda: b"")().decode()
            if "authorization_pending" in body or "slow_down" in body:
                if "slow_down" in body:
                    interval += 2
                continue
            raise
    raise TimeoutError("device code expired before approval")


def get_access_token():
    """Return a valid access token, refreshing if near expiry."""
    creds = load_credentials()
    if not creds:
        sys.exit("no credentials.json — run: python3 tidal_auth.py login")
    # tiddl tokens: no explicit expiry field; refresh proactively if older than 6 days
    age = time.time() - CREDENTIALS.stat().st_mtime
    if age > 6 * 86400 and "refresh_token" in creds:
        refreshed = post(
            f"{AUTH_URL}/token",
            {
                "client_id": CLIENT_ID,
                "refresh_token": creds["refresh_token"],
                "grant_type": "refresh_token",
                "scope": SCOPE,
            },
            basic_auth=(CLIENT_ID, CLIENT_SECRET),
        )
        refreshed.setdefault("refresh_token", creds["refresh_token"])
        save_credentials(refreshed)
        return refreshed["access_token"]
    return creds["access_token"]


def check():
    token = get_access_token()
    req = Request(
        "https://api.tidal.com/v1/countries",
        headers={"authorization": f"Bearer {token}"},
    )
    with urlopen(req) as res:
        print("token valid,", len(res.read()), "bytes of country list")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "login"
    {"login": lambda: login(), "check": check}[cmd]()
