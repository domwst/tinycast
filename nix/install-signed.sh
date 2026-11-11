#!/usr/bin/env bash
# Re-signed as the user's own identity, so macOS grants and Keychain access survive each update.
set -euo pipefail
# Activation puts GNU coreutils first, whose `mv` has no `-h`; only the system's tools will do.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

usage="usage: install-signed.sh <store Tinycast.app> <user> <identity> <keychain or ''> [dest]"
src="${1:?$usage}" user="${2:?$usage}" identity="${3:?$usage}" keychain="${4?$usage}"
dest="${5:-/Applications/Tinycast.app}"

if [ -n "$keychain" ] && [[ "$keychain" != /* ]]; then
  home="$(dscl . -read "/Users/$user" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
  keychain="$home/$keychain"
fi

# Activation runs as root; the identity lives in the user's keychain, so signing runs as them.
as_user=()
# Root keeps its stamp and staging out of /Applications, which anyone in admin can write into.
work="$(dirname "$dest")"
if [ "$(id -u)" = 0 ]; then
  as_user=(launchctl asuser "$(id -u "$user")" sudo -H -u "$user" --)
  work=/var/db/tinycast-nix
  mkdir -p "$work"
  chown root:wheel "$work"
  chmod 0755 "$work"
  rm -f "$(dirname "$dest")/.tinycast-installed-from"
fi
stamp="$work/.tinycast-installed-from"
# The identity is part of what was installed, so changing it re-signs even an unchanged build.
installed="$src"$'\n'"$identity"$'\n'"$keychain"

# Unchanged since the last install: leave the signed copy, and every grant on it, alone.
if [ -d "$dest" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$installed" ]; then
  exit 0
fi

staging="$(mktemp -d "$work/.tinycast-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
# Readable so the user can sign inside it, never writable, so nothing in it can be swapped.
chmod 0755 "$staging"
ditto "$src" "$staging/Tinycast.app"
chmod -R u+w "$staging/Tinycast.app"
if [ "$(id -u)" = 0 ]; then
  chown -R "$user":staff "$staging/Tinycast.app"
fi

# `${a[@]+"${a[@]}"}`: an empty array is unbound under the stock bash 3.2 with `set -u`.
run_as_user() { ${as_user[@]+"${as_user[@]}"} "$@"; }

keychain_args=()
if [ -n "$keychain" ]; then
  keychain_args=(--keychain "$keychain")
  # Asks for the keychain's password when it is locked, which is the point of keeping it apart.
  run_as_user security unlock-keychain "$keychain"
fi

sign() {
  run_as_user codesign --force --sign "$identity" ${keychain_args[@]+"${keychain_args[@]}"} \
    --options runtime --preserve-metadata=identifier,entitlements --timestamp=none "$1"
}

# Inside out: a bundle's seal covers the code it contains, so helpers are signed first.
for helper in "$staging/Tinycast.app/Contents/Helpers/"*; do
  sign "$helper"
done
sign "$staging/Tinycast.app"
if [ -n "$keychain" ]; then
  # Locked at once, not after its timeout: nothing else needs the key until the next update.
  run_as_user security lock-keychain "$keychain" || true
fi
run_as_user codesign --verify --strict --deep "$staging/Tinycast.app"

# `-h` renames over a symlink planted at either path instead of moving into what it points at.
if [ -e "$dest" ] || [ -L "$dest" ]; then
  mv -h "$dest" "$staging/previous.app"
fi
if ! mv -h "$staging/Tinycast.app" "$dest"; then
  if [ -e "$staging/previous.app" ]; then mv -h "$staging/previous.app" "$dest" || true; fi
  exit 1
fi
printf '%s' "$installed" > "$stamp"

if pgrep -xq Tinycast; then
  echo "Tinycast was updated; quit and reopen it to run the new version." >&2
fi
