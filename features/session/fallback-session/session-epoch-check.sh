# session-epoch-check [-q]
#
# Does the user's ACTIVE home generation match the running system's epoch?
# Called by a session launcher (guarded-session) before it starts the normal
# session, and usable by hand. Prints one key=value line unless -q.
#
#   exit 0  match -- or nothing to compare: the system records no epoch, or
#           its surface is empty (no system code loaded into user processes,
#           so no home can mismatch it)
#   exit 1  mismatch
#   exit 2  unrecorded: the generation has no `epoch` file (built without
#           homeLib.<host>.epochModule, or by the integrated home-manager)
#   exit 3  no home generation at all (first login)

quiet=0
[ "${1:-}" = -q ] && quiet=1

sys=$(system_epoch)
g=$(current_home_gen 2>/dev/null || true)
e=""
[ -n "$g" ] && e=$(gen_epoch "$g")
n=""
[ -n "$g" ] && n=$(gen_number_of "$g")

if [ -z "$sys" ] || [ "$sys" = empty ]; then
  status=match rc=0
elif [ -z "$g" ] || [ ! -e "$g" ]; then
  status=nohome rc=3
elif [ -z "$e" ]; then
  status=unrecorded rc=2
elif [ "$e" = "$sys" ]; then
  status=match rc=0
else
  status=mismatch rc=1
fi

[ "$quiet" = 1 ] || printf 'status=%s system=%s home=%s generation=%s\n' \
  "$status" "${sys:-none}" "${e:-none}" "${n:-none}"
exit "$rc"
