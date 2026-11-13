#!/usr/bin/env python3
"""Ensure a distribution provisioning profile exists on the build box (copied from TrueOffset).

Runs ON THE BUILD BOX. Finds the bundle ID and the distribution certificate whose
private key is in the build keychain (Developer ID Application for MAC_APP_DIRECT), creates the profile through the App Store
Connect API if it is missing, and installs it where xcodebuild looks.

Needs ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH in the environment, python3 with
pyjwt + cryptography, openssl, security.

Usage: asc_profile.py <bundle identifier> <profile name> [IOS_APP_STORE|TVOS_APP_STORE|MAC_APP_STORE|MAC_APP_DIRECT]
"""
import base64, json, os, re, subprocess, sys, time, urllib.error, urllib.request

import jwt

KEY_ID = os.environ["ASC_KEY_ID"]
ISSUER = os.environ["ASC_ISSUER_ID"]
KEY_PATH = os.path.expanduser(os.environ["ASC_KEY_PATH"])
KEYCHAIN = os.path.expanduser(os.environ.get("KEYCHAIN", "~/build.keychain-db"))
PROFILE_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")
BASE = "https://api.appstoreconnect.apple.com/v1"


def token():
    with open(KEY_PATH) as f:
        key = f.read()
    # Apple rejects tokens that live a full 20 minutes
    now = int(time.time())
    payload = {"iss": ISSUER, "iat": now, "exp": now + 1140, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, key, algorithm="ES256", headers={"kid": KEY_ID})


TOKEN = token()


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} {method} {path}: {e.read().decode()[:600]}", file=sys.stderr)
        raise


def keychain_serials():
    """Serial numbers of every certificate in the build keychain, uppercase hex."""
    pems = subprocess.run(["security", "find-certificate", "-a", "-p", KEYCHAIN],
                          capture_output=True, text=True, check=True).stdout
    serials = set()
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pems, re.S):
        out = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem,
                             capture_output=True, text=True).stdout
        if "=" in out:
            serials.add(out.strip().split("=", 1)[1].upper().lstrip("0"))
    return serials


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        raise SystemExit(2)
    identifier, name = sys.argv[1], sys.argv[2]
    profile_type = sys.argv[3] if len(sys.argv) > 3 else "IOS_APP_STORE"

    bundles = [b for b in req("GET", f"/bundleIds?filter[identifier]={identifier}&limit=200")["data"]
               if b["attributes"]["identifier"] == identifier]
    if not bundles:
        raise SystemExit(f"no bundle ID {identifier} on this account")
    bundle = bundles[0]["id"]

    local = keychain_serials()
    # A Developer ID profile is signed for the Developer ID Application certificate, not Apple Distribution
    cert_types = "DEVELOPER_ID_APPLICATION,DEVELOPER_ID_APPLICATION_G2" if profile_type == "MAC_APP_DIRECT" else "DISTRIBUTION"
    certs = req("GET", f"/certificates?filter[certificateType]={cert_types}&limit=200")["data"]
    cert = next((c for c in certs if c["attributes"]["serialNumber"].upper().lstrip("0") in local), None)
    if cert is None:
        raise SystemExit(f"no {cert_types} certificate on the account matches a certificate in {KEYCHAIN}")
    print("distribution certificate:", cert["id"], cert["attributes"]["name"])

    existing = [p for p in req("GET", f"/profiles?filter[name]={urllib.request.quote(name)}&limit=200")["data"]
                if p["attributes"]["name"] == name]
    active = [p for p in existing if p["attributes"]["profileState"] == "ACTIVE"]
    if active:
        profile = active[0]
        print("profile exists:", profile["id"])
    else:
        for stale in existing:
            req("DELETE", f"/profiles/{stale['id']}")
            print("deleted invalid profile:", stale["id"])
        profile = req("POST", "/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": profile_type},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
        print("created profile:", profile["id"])

    attributes = profile["attributes"]
    os.makedirs(PROFILE_DIR, exist_ok=True)
    # Xcode looks for a Mac profile under a different extension
    extension = ".provisionprofile" if profile_type.startswith("MAC_") else ".mobileprovision"
    path = os.path.join(PROFILE_DIR, attributes["uuid"] + extension)
    with open(path, "wb") as f:
        f.write(base64.b64decode(attributes["profileContent"]))
    print(f"installed '{name}' ({profile_type}, expires {attributes['expirationDate'][:10]}) -> {path}")


if __name__ == "__main__":
    main()
