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
# mscoree=d: KakaoTalk needs no .NET, and without it wine offers to download
#   Mono on a fresh prefix and BLOCKS the install behind a modal dialog.
# winemenubuilder.exe=d: stops wine turning the installer's Windows shortcuts
#   into .desktop files. They would duplicate the entry this package already
#   ships, point into the prefix rather than at the launcher, and cost time
#   during install.
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,winemenubuilder.exe=d}"

mkdir -p "$root"
stamp="$root/installed-from"

# A SMALL curated Korean set, symlinked so a font bump follows the store path.
#
# This deliberately does NOT link whole font directories. The first version did,
# which put 35 files and 176 MB into the prefix -- including two ~30 MB
# variable-font CJK collections that wine's GDI engine parses poorly -- and wine
# enumerates everything here at startup. The system fontconfig already serves
# Noto Sans CJK KR for :lang=ko and wine reads fontconfig, so the bulk of that
# was redundant as well as expensive. Measured 2026-09-16.
link_fonts() {
  local dest="$WINEPREFIX/drive_c/windows/Fonts" src base want
  mkdir -p "$dest"
  want=""
  for src in @fontFiles@; do
    [ -e "$src" ] || continue
    base="$(basename "$src")"
    want="$want $base"
    # IDEMPOTENT, and that is the point rather than a nicety: `ln -sfn` over an
    # already-correct symlink still deletes and recreates it, which moves its
    # timestamp and invalidates wine's font cache -- so the old unconditional
    # version forced a full font rescan on EVERY launch.
    [ "$(readlink "$dest/$base" 2>/dev/null)" = "$src" ] && continue
    ln -sfn "$src" "$dest/$base"
  done

  # Drop links this launcher previously made but no longer wants, so a prefix
  # created by an older version does not keep paying for fonts we dropped.
  # Only ever removes SYMLINKS INTO THE STORE -- anything the user or the
  # installer put here is left alone.
  local f
  for f in "$dest"/*; do
    [ -L "$f" ] || continue
    case "$(readlink "$f")" in /nix/store/*) ;; *) continue ;; esac
    case " $want " in *" $(basename "$f") "*) continue ;; esac
    rm -f "$f"
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
