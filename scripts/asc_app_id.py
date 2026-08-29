#!/usr/bin/env python3
"""Print the numeric App Store Connect app id for a bundle id, or exit 1.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 or ASC_KEY_PATH (same as upload_asc.py).
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import jwt  # PyJWT

KEY = os.environ.get("ASC_KEY_P8") or open(os.path.expanduser(os.environ["ASC_KEY_PATH"])).read()
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        KEY, algorithm="ES256", headers={"kid": KEY_ID},
    )


def main():
    bundle_id = sys.argv[1]
    url = "https://api.appstoreconnect.apple.com/v1/apps?" + urllib.parse.urlencode(
        {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId"}
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    data = json.load(urllib.request.urlopen(req))
    for app in data.get("data", []):
        if app["attributes"]["bundleId"] == bundle_id:
            print(app["id"])
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
