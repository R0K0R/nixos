# guarded-session [--ignore-epoch] <command...>
#
# What every guarded session entry's Exec= runs (my.fallback-session.guard):
# greetd starts THIS as the user, and it either execs the session the greeter
# asked for or the fallback session. The check reads the generation's epoch
# as data; nothing of the user's home runs before the decision -- except the
# ~/.profile greetd itself sources before any session command (its
# source_profile), which is outside the guard's reach.
#
#   match                  -> the requested session
#   mismatch, no home      -> fallback-session, which offers [s] "start anyway"
#   unrecorded             -> the session, or the fallback when GUARD_STRICT=1
#   --ignore-epoch         -> the session, logged; the "<Name> (ignore epoch)"
#                             greeter entries run this
#   not a guarded user     -> the session (GUARD_USERS: accounts whose session
#                             is a home-manager home; a kiosk or system-default
#                             account has no generation to compare)
#
# EPOCH_GUARD=passed is exported into the session it starts, and a nested
# guarded-session passes straight through: "Hyprland (uwsm-managed)" names
# hyprland.desktop, which uwsm resolves to the GUARDED entry, so the guard runs
# twice on that path and "start anyway" must not be asked for again.

ignore=0
if [ "${1:-}" = --ignore-epoch ]; then
  ignore=1
  shift
fi
[ $# -gt 0 ] || { echo "usage: guarded-session [--ignore-epoch] <session command...>" >&2; exit 2; }

log() { logger -t guarded-session -- "$USER: $*" 2>/dev/null || true; }

if [ "${EPOCH_GUARD:-}" = passed ]; then
  exec "$@"
fi
export EPOCH_GUARD=passed

guarded=0
for u in ${GUARD_USERS:-}; do
  [ "$u" = "$USER" ] && guarded=1
done
[ "$guarded" = 1 ] || exec "$@"

check=$(session-epoch-check)
rc=$?
if [ "$ignore" = 1 ]; then
  log "started ignoring the epoch ($check): $*"
  exec "$@"
fi
case $rc in
  0) exec "$@" ;;
  2) [ "${GUARD_STRICT:-0}" = 1 ] || exec "$@" ;;
esac
log "diverted to the fallback session ($check)"
# EPOCH_GUARD=passed reaches the fallback too, deliberately: its [s] execs the
# requested session, and a nested guard on that path must let it through.
exec fallback-session -- "$@"
