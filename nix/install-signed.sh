#!/usr/bin/env bash
# Re-signed as the user's own identity, so macOS grants and Keychain access survive each update.
set -euo pipefail

usage="usage: install-signed.sh <store Tinycast.app> <user> <identity> <keychain or ''> [dest]"
src="${1:?$usage}" user="${2:?$usage}" identity="${3:?$usage}" keychain="${4?$usage}"
dest="${5:-/Applications/Tinycast.app}"

if [ -n "$keychain" ] && [[ "$keychain" != /* ]]; then
  home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')"
  keychain="$home/$keychain"
fi
stamp="$dest/../.tinycast-installed-from"

# Unchanged since the last install: leave the signed copy, and every grant on it, alone.
if [ -d "$dest" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$src" ]; then
  exit 0
fi

# Activation runs as root; the identity lives in the user's keychain, so signing runs as them.
as_user=()
if [ "$(id -u)" = 0 ]; then
  as_user=(/bin/launchctl asuser "$(id -u "$user")" /usr/bin/sudo -u "$user" --)
fi

staging="$(mktemp -d "$(dirname "$dest")/.tinycast-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$src" "$staging/Tinycast.app"
chmod -R u+w "$staging"
if [ "$(id -u)" = 0 ]; then
  chown -R "$user":staff "$staging"
fi

keychain_args=()
if [ -n "$keychain" ]; then
  keychain_args=(--keychain "$keychain")
  # Asks for the keychain's password when it is locked, which is the point of keeping it apart.
  "${as_user[@]}" /usr/bin/security unlock-keychain "$keychain"
fi

sign() {
  "${as_user[@]}" /usr/bin/codesign --force --sign "$identity" "${keychain_args[@]}" \
    --options runtime --preserve-metadata=identifier,entitlements --timestamp=none "$1"
}

# Inside out: a bundle's seal covers the code it contains, so helpers are signed first.
for helper in "$staging/Tinycast.app/Contents/Helpers/"*; do
  sign "$helper"
done
sign "$staging/Tinycast.app"
"${as_user[@]}" /usr/bin/codesign --verify --strict --deep "$staging/Tinycast.app"

if [ -e "$dest" ]; then
  mv "$dest" "$staging/previous.app"
fi
mv "$staging/Tinycast.app" "$dest"
printf '%s' "$src" > "$stamp"
