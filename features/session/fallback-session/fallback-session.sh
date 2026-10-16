# fallback-session [-- <normal session command...>]
#
# The minimal session: cage running the SYSTEM's kitty, both from the system
# package set, with fallback-banner in it. Nothing from the user's home runs
# unless they ask: kitty starts with --config NONE (a home config from another
# epoch may name store paths that are gone), and the banner is bash, not the
# login shell.
#
# [s] in the banner means "start the normal session anyway". cage cannot exec
# into another compositor, so the banner leaves its choice in a file and exits;
# cage ends with its last client and this script then execs the normal
# session in the same login, in place of itself.

if [ "${1:-}" = -- ]; then shift; fi
if [ $# -eq 0 ] && [ -n "${FALLBACK_DEFAULT_NORMAL:-}" ]; then
  # shellcheck disable=SC2086 # a command line from the system config
  set -- $FALLBACK_DEFAULT_NORMAL
fi

rundir=${XDG_RUNTIME_DIR:-/tmp}
choice=$(mktemp "$rundir/fallback-session.XXXXXX")
export FALLBACK_CHOICE_FILE=$choice
export FALLBACK_HAS_NORMAL=$([ $# -gt 0 ] && echo 1 || echo 0)

cage -s -- kitty --config NONE \
  -o confirm_os_window_close=0 \
  -o font_size=12 \
  --title "fallback session" \
  fallback-banner

what=$(cat "$choice" 2>/dev/null || true)
rm -f "$choice"
if [ "$what" = normal ] && [ $# -gt 0 ]; then
  exec "$@"
fi
