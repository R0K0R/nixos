#!/usr/bin/env bash
# Re-pin the KakaoTalk installer: ./update.sh
#
# Kakao's download URL is UNVERSIONED -- it always serves the current build --
# so there is no index to query and nothing to diff against. The hash in
# package.nix is the pin, and a Kakao release breaks the build with a mismatch
# until this is run. That is deliberate: the alternative is silently fetching
# whatever is on the CDN today.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

URL="https://app-pc.kakaocdn.net/talk/win32/KakaoTalk_Setup.exe"

echo "fetching $URL ..."
OUT="$(nix store prefetch-file --json "$URL")"
HASH="$(printf '%s' "$OUT" | nix run nixpkgs#jq -- -r .hash)"
STORE="$(printf '%s' "$OUT" | nix run nixpkgs#jq -- -r .storePath)"

# The version is not in the URL or any manifest; it lives in the PE resources.
VERSION="$(strings -a -el "$STORE" | grep -aoE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)"
if [ -z "$VERSION" ]; then
  echo "could not read a version out of the installer; leaving version untouched" >&2
else
  sed -i -E "s|(version = \")[0-9]+(\.[0-9]+)*(\";)|\1$VERSION\3|" package.nix
fi

sed -i -E "s|(hash = \")sha256-[A-Za-z0-9+/=]+(\";)|\1$HASH\2|" package.nix

echo "pinned KakaoTalk ${VERSION:-<unknown version>} ($HASH)"
echo "note: the prefix reinstalls on next launch, since the stamp tracks the installer path"
