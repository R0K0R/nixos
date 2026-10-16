# guarded-session <command...>
#
# What a session entry's Exec= runs INSTEAD of the compositor when the epoch
# guard is wired in: start the normal session if the home generation matches
# the system epoch, otherwise the fallback session, which still offers [s] to
# start the normal one anyway. The check reads the generation's epoch as data;
# nothing of the user's home runs before the decision.

[ $# -gt 0 ] || { echo "usage: guarded-session <session command...>" >&2; exit 2; }

session-epoch-check -q
rc=$?
case $rc in
  0) exec "$@" ;;
  2) [ "${GUARD_STRICT:-0}" = 1 ] || exec "$@" ;;
esac
exec fallback-session -- "$@"
