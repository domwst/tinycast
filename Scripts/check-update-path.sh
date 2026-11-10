#!/bin/bash
# Fail unless the last release on <channel> would install <app>, so no release strands a copy.
set -euo pipefail

APP="${1:?usage: check-update-path.sh <app> <beta|stable>}" CHANNEL="${2:?}"
case "$CHANNEL" in
    beta) PRERELEASE=true ;;
    stable) PRERELEASE=false ;;
    *) echo "✗ unknown channel: $CHANNEL" >&2 && exit 1 ;;
esac

TAG="$(gh release list --exclude-drafts --limit 50 --json tagName,isPrerelease \
    --jq "[.[] | select(.isPrerelease == $PRERELEASE)][0].tagName // empty")"
if [ -z "$TAG" ]; then
    echo "No earlier $CHANNEL release, so no copy to update from."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ZIP="Tinycast-${TAG#v}.zip"
gh release download "$TAG" --pattern "$ZIP" --dir "$WORK"
ditto -x -k "$WORK/$ZIP" "$WORK/expanded"
OLD="$(find "$WORK/expanded" -maxdepth 1 -name '*.app' | head -n1)"
[ -n "$OLD" ] || { echo "✗ $ZIP holds no app" >&2 && exit 1; }

update_key() {
    /usr/libexec/PlistBuddy -c 'Print :TinycastUpdatePublicKey' "$1/Contents/Info.plist" 2>/dev/null || true
}
# An installed copy needs both: the zip signed by the key it ships, and its designated requirement.
OLD_KEY="$(update_key "$OLD")"
if [ -z "$OLD_KEY" ] || [ "$OLD_KEY" != "$(update_key "$APP")" ]; then
    echo "::error::$TAG does not trust this build's update key, so it could never install it"
    exit 1
fi

REQUIREMENT="$(codesign -d -r- "$OLD" 2>/dev/null | sed -n 's/^#* *designated => //p' || true)"
[ -n "$REQUIREMENT" ] || { echo "✗ cannot read $TAG's designated requirement" >&2 && exit 1; }
if ! codesign --verify --strict -R "=$REQUIREMENT" "$APP"; then
    echo "::error::this build does not satisfy $TAG's designated requirement, so it could never install it"
    exit 1
fi
echo "✓ $TAG trusts this build's update key and its signature"
