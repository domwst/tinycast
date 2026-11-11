#!/bin/bash
# Merge the strings the compiler extracted into Localizable.xcstrings, as an Xcode build in the IDE
# does; `xcodebuild` alone never writes them back. Run after changing any UI text.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# `.noindex` keeps the build out of Spotlight, so its apps never list beside the installed one.
DERIVED=build/strings.noindex
xcodebuild build -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
    CODE_SIGNING_ALLOWED=NO -derivedDataPath "$DERIVED" -quiet
# xcodebuild registers what it builds, and this copy would then compete for `raycast://` links.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
while IFS= read -r app; do "$lsregister" -u "$app" >/dev/null 2>&1 || true; done < <(
    find "$DERIVED/Build/Products" -name '*.app' -type d -prune
)

# A read loop rather than `mapfile`, which is bash 4 — macOS ships bash 3.2.
args=()
while IFS= read -r f; do args+=(--stringsdata "$f"); done < <(
    find "$DERIVED/Build/Intermediates.noindex/Tinycast.build/Debug/Tinycast.build" \
        -name '*.stringsdata'
)
# The catalog's file name is its table, so only `Localizable` strings land in it.
xcrun xcstringstool sync Tinycast/Resources/Localizable.xcstrings "${args[@]}"

node Scripts/check-localizations.js
