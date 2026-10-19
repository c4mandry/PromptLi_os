#!/bin/sh
# Publish a promptLi OS ISO as a GitHub release.
# Usage: tools/github_release.sh <version> <iso-path>
# Auth: token from ~/.git-credentials (same one git push uses) or $GITHUB_TOKEN.
set -eu

VERSION="$1"
ISO="$2"
[ -f "$ISO" ] || { echo "error: ISO not found: $ISO" >&2; exit 1; }

if [ -n "${GITHUB_TOKEN:-}" ]; then
    TOKEN="$GITHUB_TOKEN"
else
    TOKEN=$(python3 - << 'PY'
import urllib.parse, os
for p in [os.path.expanduser('~/.git-credentials'), '/root/.git-credentials']:
    try:
        for line in open(p):
            u = urllib.parse.urlparse(line.strip())
            if u.hostname == 'github.com':
                print(u.password)
                raise SystemExit
    except OSError:
        pass
PY
)
fi
[ -n "$TOKEN" ] || { echo "error: no GitHub token" >&2; exit 1; }

REPO="c4mandry/PromptLi_os"
TAG="v$VERSION"
SHA=$(sha256sum "$ISO" | cut -d' ' -f1)

echo "→ Publishing promptLi OS $VERSION to GitHub releases…"

python3 - "$TOKEN" "$REPO" "$TAG" "$VERSION" "$SHA" << 'PY'
import json, sys, urllib.request
token, repo, tag, version, sha = sys.argv[1:6]
def req(method, url, data=None):
    r = urllib.request.Request(url, method=method, data=data, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "promptli-release"})
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

status, raw = req("GET", f"https://api.github.com/repos/{repo}/releases/tags/{tag}")
if status == 200:
    print(json.loads(raw)["id"])
else:
    body = json.dumps({
        "tag_name": tag,
        "name": f"promptLi OS {version}",
        "body": f"promptLi OS {version}\\n\\nLive manifest: https://webnotes.work/os\\nsha256: {sha}\\n\\nDownload: https://webnotes.work/api/os/iso",
        "draft": False,
        "prerelease": False,
    }).encode()
    status, raw = req("POST", f"https://api.github.com/repos/{repo}/releases", body)
    if status not in (200, 201):
        print(f"create failed: {status} {raw[:300]}", file=sys.stderr)
        sys.exit(1)
    print(json.loads(raw)["id"])
PY
RELEASE_ID=$(python3 - "$TOKEN" "$REPO" "$TAG" << 'PY'
import json, sys, urllib.request
token, repo, tag = sys.argv[1:]
r = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases/tags/{tag}",
    headers={"Authorization": f"token {token}",
             "Accept": "application/vnd.github+json",
             "User-Agent": "promptli-release"})
with urllib.request.urlopen(r) as resp:
    print(json.loads(resp.read())["id"])
PY
)

echo "→ Uploading $(basename "$ISO") (release id $RELEASE_ID)…"
curl -sS -o /tmp/promptli-release-upload.json -w "upload HTTP %{http_code}\n" \
    -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$ISO" \
    "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=promptli-os-$VERSION-amd64.iso"

echo "✅ Release v$VERSION: https://github.com/$REPO/releases/tag/$TAG"
