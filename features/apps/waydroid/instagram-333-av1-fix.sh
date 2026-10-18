#!/bin/sh
# Run as: sudo sh features/waydroid/instagram-333-av1-fix.sh [--clear]
# (not wired into the config; a one-off fix run by hand)
# Downgrades Instagram to the APK at ~/Instagram.apk (333.0.0.42.91) in place and
# applies the AV1 workaround from waydroid/waydroid#2052 (comment 6050667507):
# mobileconfig group 45757, 12=false (no platform AV1 decoder), 17=true (Dav1d via
# OpenGL instead of the Canvas path that fails to lock the native window).
# Installed as an update (pm install -r -d): Android only accepts it if it is
# signed with the same key as the installed Instagram, and keeps your data.
set -eu
# --clear: skip the install and wipe Instagram's data first (333 crashes at start
# on the data 450 left behind: "initSupplier() should get call before
# getInstance()"); you log in again afterwards.
clear=; [ "${1:-}" = --clear ] && clear=1
apk=/home/r0k0r/Instagram.apk
data=/home/r0k0r/.local/share/waydroid/data
[ -d "$data/local/tmp" ] || data=/var/lib/waydroid/data
[ -d "$data/local/tmp" ] || { echo "Waydroid's /data not found"; exit 1; }

if [ -n "$clear" ]; then
  waydroid shell -- pm clear com.instagram.android </dev/null
else
cp "$apk" "$data/local/tmp/ig-333.apk"
chmod 644 "$data/local/tmp/ig-333.apk"
waydroid shell -- pm install -r -d /data/local/tmp/ig-333.apk </dev/null
rm -f "$data/local/tmp/ig-333.apk"
waydroid shell -- dumpsys package com.instagram.android </dev/null | grep -m1 versionName
fi

waydroid shell -- sh -c '
  pkg=/data/data/com.instagram.android
  file=$pkg/files/mobileconfig/mc_overrides.json
  uid=$(stat -c %u "$pkg")
  mkdir -p "$pkg/files/mobileconfig"
  [ -f "$file" ] && cp "$file" "$file.bak-$(date +%s)"
  printf "%s\n" "{\"45757\":[\"12: : false\",\"17: : true\"],\"_qe_overrides_\":[]}" > "$file"
  chown "$uid:$uid" "$pkg/files" "$pkg/files/mobileconfig" "$file"
  chmod 600 "$file"
  restorecon -RF "$pkg/files" 2>/dev/null || true
  am force-stop com.instagram.android
  cat "$file"
' </dev/null
echo "Done. Open Instagram and try Reels."
