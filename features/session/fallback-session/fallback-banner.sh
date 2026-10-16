# fallback-banner: the menu shown inside the fallback session.

repo=${HM_REPO:-$HOME/config/home}
bold=$(printf '\033[1m') red=$(printf '\033[31m') green=$(printf '\033[32m') off=$(printf '\033[0m')

pause() { printf '\n[press a key]'; read -rsn1 _; }

choose() {
  printf '%s' "$1" > "${FALLBACK_CHOICE_FILE:-/dev/null}"
  exit 0
}

while :; do
  clear
  sys=$(system_epoch)
  check=$(session-epoch-check)
  status=$(printf '%s' "$check" | sed -n 's/^status=\([a-z]*\).*/\1/p')
  home=$(printf '%s' "$check" | sed -n 's/.* home=\([^ ]*\).*/\1/p')
  gen=$(printf '%s' "$check" | sed -n 's/.* generation=\([^ ]*\).*/\1/p')
  match=$(newest_gen_of_epoch "$sys")
  match_n=${match%% *}

  printf '%sFallback session%s on %s -- %s@%s\n\n' "$bold" "$off" "$(system_host)" "$USER" "$(system_rev)"
  printf '  system epoch            %s\n' "${sys:-<not recorded>}"
  case $status in
    match) c=$green ;;
    *) c=$red ;;
  esac
  printf '  home generation %-7s %s%s (%s)%s\n' "${gen}" "$c" "$home" "$status" "$off"
  if [ -n "$match_n" ]; then
    printf '  newest generation built for this epoch: %s\n' "$match_n"
  else
    printf '  no home generation was built for this epoch\n'
  fi
  [ -s "$(hm_switch_state)/last-failed.log" ] && printf '  %slast hm-switch failed%s (%s)\n' "$red" "$off" "$(hm_switch_state)/last-failed.log"

  printf '\n'
  [ -n "$match_n" ] && [ "$status" != match ] && printf '  [r] roll back to generation %s\n' "$match_n"
  printf '  [u] hm-switch --update  (relock to this epoch, rebuild home)\n'
  command -v claude >/dev/null && printf '  [c] ask Claude Code, in %s\n' "$repo"
  [ "${FALLBACK_HAS_NORMAL:-0}" = 1 ] && printf '  [s] start the normal session anyway\n'
  printf '  [t] terminal\n  [q] log out\n\n> '
  read -rsn1 key
  printf '%s\n\n' "$key"
  case $key in
    r) [ -n "$match_n" ] && hm-rollback "$match_n"; pause ;;
    u) hm-switch --update --repo "$repo"; pause ;;
    c)
      if command -v claude >/dev/null; then
        d=$repo
        [ -d "$d" ] || d=$HOME
        (cd "$d" && claude "$(fallback-brief)")
      fi
      ;;
    s) [ "${FALLBACK_HAS_NORMAL:-0}" = 1 ] && choose normal ;;
    t) "${SHELL:-bash}" -l || bash --norc ;;
    q) choose quit ;;
  esac
done
