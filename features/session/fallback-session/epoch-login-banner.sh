# epoch-login-banner: the TTY/ssh variant. Run as root by pam_exec at
# open_session (stdout goes to the user's terminal); prints a banner when the
# user's active home generation was built for another epoch. Never fails the
# login: every path exits 0.
#
# Runs as ROOT over files the user controls, so: the generation is only
# followed if it resolves into /nix/store (immutable, and not a path the user
# can point at /etc/shadow), and its epoch is read through gen_epoch's
# length cap and alphabet filter.

[ -z "${PAM_TYPE:-}" ] || [ "$PAM_TYPE" = open_session ] || exit 0
u=${PAM_USER:-${USER:-}}
[ -n "$u" ] || exit 0
h=$(getent passwd "$u" | cut -d: -f6)
[ -n "$h" ] || exit 0
unset XDG_STATE_HOME

sys=$(system_epoch)
[ -n "$sys" ] && [ "$sys" != empty ] || exit 0
g=$(readlink -f "$h/.local/state/home-manager/gcroots/current-home" 2>/dev/null || true)
case $g in /nix/store/*) ;; *) exit 0 ;; esac
e=$(gen_epoch "$g")
[ -n "$e" ] || exit 0
[ "$e" = "$sys" ] && exit 0

cat <<MSG

  !! Your home generation was built for system epoch $e,
  !! but this system runs epoch $sys.
  !! Programs from your home may load mismatched system code.
  !! See: session-epoch-check, hm-rollback (lists matching generations),
  !!      hm-switch --update, or fallback-brief for the full picture.

MSG
exit 0
