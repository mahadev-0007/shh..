#!/usr/bin/env python3
"""Create a GitHub release and upload assets, using a token from the
environment. Used by release.sh when the gh CLI isn't set up."""
import json, os, pathlib, sys, urllib.error, urllib.request

token = os.environ["TOKEN"]
repo = os.environ["REPO"]
version = os.environ["VERSION"]
assets = [pathlib.Path(p) for p in (os.environ.get("ARCHIVE"), os.environ.get("DMG")) if p]
notes_file = pathlib.Path("RELEASE_NOTES.md")
notes = notes_file.read_text().strip() if notes_file.exists() else f"Version {version}"


def api(url, data=None, method=None, ctype="application/json"):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {token}")
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"_error": e.code, "_body": e.read().decode()[:300]}


rel = api(f"https://api.github.com/repos/{repo}/releases/tags/v{version}")
if "_error" in rel:
    rel = api(f"https://api.github.com/repos/{repo}/releases",
              data=json.dumps({"tag_name": f"v{version}", "name": f"shh {version}",
                               "body": notes}).encode())
if "_error" in rel:
    sys.exit(f"could not create the release: {rel['_error']} {rel['_body']}")

print(f"  release: {rel['html_url']}")
existing = {a["name"]: a["url"] for a in rel.get("assets", [])}

for path in assets:
    if not path.exists():
        print(f"  skipping missing {path}")
        continue
    # replacing an asset means deleting it first; GitHub won't overwrite
    if path.name in existing:
        api(existing[path.name], method="DELETE")
    up = rel["upload_url"].split("{")[0] + "?name=" + path.name
    a = api(up, data=path.read_bytes(), ctype="application/octet-stream")
    if "_error" in a:
        sys.exit(f"  upload of {path.name} failed: {a['_error']} {a['_body']}")
    print(f"  asset:   {a['name']}  {a['size']} bytes")
