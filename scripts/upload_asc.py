#!/usr/bin/env python3
"""Upload an .ipa or .pkg to App Store Connect via the Build Upload API.

Adapted from the pipeline that actually shipped danielalanbates/descend-watch to
TestFlight. Uses the Build Upload API directly rather than altool: altool has no
watchOS type and iTMSTransporter no longer ships with Xcode, and the raw API is
the only path that has been proven to work on this account.

Env:
  ASC_KEY_ID     App Store Connect API key id
  ASC_ISSUER_ID  ASC API issuer id (UUID)
  ASC_KEY_P8     contents of the .p8 (or ASC_KEY_PATH pointing at the file)
  APP_ID         the numeric App Store Connect app id
  IPA_PATH       path to the artifact to upload
  PLATFORM       IOS | MAC_OS  (default IOS)
  VER            CFBundleShortVersionString (default 1.0.0)
  BUILD          CFBundleVersion (default 1)
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
KEY = os.environ.get("ASC_KEY_P8") or open(os.environ["ASC_KEY_PATH"]).read()
APP_ID = os.environ.get("APP_ID") or ""
BUNDLE_ID = os.environ.get("BUNDLE_ID", "org.batesai.endgamefitness")
ARTIFACT = os.environ["IPA_PATH"]
PLATFORM = os.environ.get("PLATFORM", "IOS")


def token():
    """ASC tokens are short-lived; mint a fresh one per call rather than reusing."""
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        KEY,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def call(method, url, body=None, headers=None, raw=False):
    h = {"Authorization": "Bearer " + token()}
    if body is not None and not raw:
        body = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=120)
        d = r.read()
        return json.loads(d) if d and not raw else d
    except urllib.error.HTTPError as e:
        print(f"{method} {url} -> {e.code}\n{e.read().decode()[:2000]}", file=sys.stderr)
        raise


def resolve_app_id():
    """APP_ID may be unset: look the app up by bundle id. Exit 78 (EX_CONFIG)
    when App Store Connect has no app record yet — creating one is web-UI only."""
    global APP_ID
    if APP_ID:
        return APP_ID
    r = call("GET", f"{API}/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=name,bundleId")
    apps = r.get("data", []) if isinstance(r, dict) else []
    if not apps:
        print(f"NO APP RECORD for {BUNDLE_ID} in App Store Connect. Create it (My Apps -> + -> New App, "
              f"iOS + macOS, bundle id {BUNDLE_ID}); this job will succeed on the next run.")
        sys.exit(78)
    APP_ID = apps[0]["id"]
    print(f"resolved app id {APP_ID} ({apps[0]['attributes']['name']})")
    return APP_ID


resolve_app_id()
data = open(ARTIFACT, "rb").read()
print(f"artifact: {ARTIFACT} ({len(data)} bytes, md5 {hashlib.md5(data).hexdigest()})")

uti = "com.apple.ipa" if PLATFORM == "IOS" else "com.apple.pkg"

up = call("POST", f"{API}/buildUploads", {
    "data": {
        "type": "buildUploads",
        "attributes": {
            "cfBundleShortVersionString": os.environ.get("VER", "1.0.0"),
            "cfBundleVersion": os.environ.get("BUILD", "1"),
            "platform": PLATFORM,
        },
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
    }
})
upload_id = up["data"]["id"]
print("buildUpload:", upload_id)

f = call("POST", f"{API}/buildUploadFiles", {
    "data": {
        "type": "buildUploadFiles",
        "attributes": {
            "assetType": "ASSET",
            "fileName": os.path.basename(ARTIFACT),
            "fileSize": len(data),
            "uti": uti,
        },
        "relationships": {
            "buildUpload": {"data": {"type": "buildUploads", "id": upload_id}}
        },
    }
})
file_id = f["data"]["id"]
ops = f["data"]["attributes"]["uploadOperations"]
print(f"buildUploadFile: {file_id}, {len(ops)} upload operation(s)")

# Apple hands back an explicit chunking plan; follow it exactly and in offset
# order, or the commit below is rejected.
for op in sorted(ops, key=lambda o: o["offset"]):
    chunk = data[op["offset"]:op["offset"] + op["length"]]
    hdrs = {h["name"]: h["value"] for h in (op.get("requestHeaders") or [])}
    req = urllib.request.Request(op["url"], data=chunk, headers=hdrs, method=op["method"])
    urllib.request.urlopen(req, timeout=600).read()
    print(f"uploaded chunk offset={op['offset']} len={op['length']}")

call("PATCH", f"{API}/buildUploadFiles/{file_id}", {
    "data": {"type": "buildUploadFiles", "id": file_id, "attributes": {"uploaded": True}}
})
print("committed; polling state...")

for i in range(60):
    st = call("GET", f"{API}/buildUploads/{upload_id}")["data"]["attributes"]["state"]
    print(f"[{i}] state={st['state']} errors={st.get('errors')} warnings={st.get('warnings')}")
    if st["state"] in ("COMPLETE", "FAILED"):
        sys.exit(0 if st["state"] == "COMPLETE" else 1)
    time.sleep(30)

print("timed out waiting for processing", file=sys.stderr)
sys.exit(1)
