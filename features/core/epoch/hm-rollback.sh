# hm-rollback [--force] [<generation>]
#
# Without an argument: list home-manager generations with the epoch each was
# built for, marking those that match the running system. With one: activate
# that generation, refusing if its recorded epoch differs from the system's --
# rolling back across an epoch is what the SYSTEM rollback is for. Advisory,
# like hm-switch: --force skips the check, and so does running the
# generation's own ./activate.

force=0 gen=""
while [ $# -gt 0 ]; do
  case $1 in
    --force) force=1 ;;
    -h | --help) echo "usage: hm-rollback [--force] [<generation>]"; exit 0 ;;
    *) gen=$1 ;;
  esac
  shift
done

cur=$(system_epoch)
active=$(current_home_gen 2>/dev/null || true)

if [ -z "$gen" ]; then
  printf 'system epoch: %s\n\n' "${cur:-<not recorded>}"
  hm_generations | sort -rn | while read -r n l; do
    e=$(gen_epoch "$l")
    mark=" "
    [ -n "$e" ] && [ "$e" = "$cur" ] && mark="="
    [ "$(readlink -f "$l")" = "$active" ] && mark="${mark}*" || mark="${mark} "
    printf '%s %4s  %-20s  %s\n' "$mark" "$n" "${e:-unrecorded}" "$(date -r "$l" '+%F %R' 2>/dev/null)"
  done
  printf '\n= built for the running epoch   * active\n'
  exit 0
fi

case $gen in *[!0-9]*) echo "hm-rollback: generation must be a number" >&2; exit 2 ;; esac
d=$(hm_profile_dir) || { echo "hm-rollback: no home-manager profile found" >&2; exit 1; }
link=$d/home-manager-$gen-link
[ -e "$link" ] || { echo "hm-rollback: no generation $gen in $d" >&2; exit 1; }

e=$(gen_epoch "$link")
if [ "$e" != "$cur" ] && [ "$force" != 1 ]; then
  cat >&2 <<EOF
hm-rollback: generation $gen was built for epoch ${e:-<unrecorded>}, the system runs ${cur:-<not recorded>}.
It may load system code that no longer matches. Choose a generation marked '='
in \`hm-rollback\`, or use --force.
EOF
  exit 1
fi
exec "$link/activate"
