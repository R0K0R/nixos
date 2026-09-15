#!/usr/bin/env bash
# KakaoTalk PC under Wine. Placeholders are substituted at build time.
#
# The wine prefix is USER STATE, not a build output, and deliberately so: it
# holds the logged-in PC session. A read-only store prefix would mean logging
# in again on every rebuild, and KakaoTalk treats a re-login as a new device
# registration.
set -euo pipefail

root="${KAKAOTALK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/kakaotalk}"
export WINEPREFIX="$root/prefix"
export WINEDEBUG="${WINEDEBUG:--all}"
# KakaoTalk needs no .NET; without this wine offers to download Mono on every
# fresh prefix and blocks the install behind a dialog.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d}"

mkdir -p "$root"
stamp="$root/installed-from"

# Korean text renders as boxes without these. Symlinked rather than copied so
# a font bump follows the store path instead of leaving a stale copy behind.
link_fonts() {
  local dest="$WINEPREFIX/drive_c/windows/Fonts" src
  mkdir -p "$dest"
  for d in @fontDirs@; do
    [ -d "$d" ] || continue
    while IFS= read -r src; do
      ln -sfn "$src" "$dest/$(basename "$src")"
    done < <(find -L "$d" \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) -print)
  done
}

if [ ! -d "$WINEPREFIX" ]; then
  echo "kakaotalk: creating wine prefix at $WINEPREFIX" >&2
  # WINEARCH is meaningful ONLY here, at creation. An existing prefix records
  # its own arch in system.reg and wine hard-errors if the variable contradicts
  # it ("WINEARCH set to win64 but ... is a 32-bit installation"), so it must
  # not be exported for the launch path below.
  #
  # win32 because the client is a 32-bit binary: a win32 prefix runs it
  # directly instead of through WoW64, which is one moving part fewer.
  WINEARCH="${WINEARCH:-win32}" wineboot -i >/dev/null 2>&1 || true
  wineserver -w
fi

link_fonts

# Keyed on the INSTALLER STORE PATH, not a bare flag: re-pinning the installer
# (update.sh) changes this string, so a version bump reinstalls on next launch
# instead of silently running the old build forever.
if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "@installer@" ]; then
  echo "kakaotalk: installing @version@ into $WINEPREFIX ..." >&2
  if ! wine @installer@ /S; then
    echo "kakaotalk: silent install failed, falling back to the installer UI" >&2
    wine @installer@
  fi
  wineserver -w
  printf '%s\n' "@installer@" >"$stamp"
fi

# Located rather than hardcoded: the installer picks Program Files vs
# Program Files (x86) itself, and has moved between them across releases.
exe="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' \
       -not -ipath '*Update*' -not -iname 'KakaoTalk_Setup.exe' -print -quit || true)"
if [ -z "$exe" ]; then
  echo "kakaotalk: KakaoTalk.exe not found under $WINEPREFIX/drive_c" >&2
  echo "kakaotalk: remove $root and relaunch to reinstall" >&2
  exit 1
fi

exec wine "$exe" "$@"
