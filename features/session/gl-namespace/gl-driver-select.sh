# gl-driver-select [USER]
#
# Points USER's instance of the graphics driver view at the driver tree their
# CURRENT home generation declares ($generation/graphics-driver[-32], written
# by the home option my.graphics.driver), or at the system's tree when the
# generation declares none. Runs as root: from pam_exec (PAM_USER) in every
# mapped session stack, and from gl-driver-select@USER.service when the
# user's home-manager profile changes.
#
# What it touches, and only that:
#   $GL_NS_ROOT/inst/USER/tree[-32]    the symlinks the user's namespace sees
#                                      as /run/gl-driver/view/tree[-32]
#   $GL_NS_GCROOTS/USER[-32]           a root-owned GC root for the selected
#                                      tree, so a GC cannot pull a live
#                                      driver out from under the session
#
# Everything it reads below the user's home is user-controlled, so it only
# ever RESOLVES those paths (realpath: lstat + readlink, under a timeout --
# a FUSE mount in the home could otherwise stall the login) and accepts the
# result only if it is a top-level, root-owned directory in /nix/store. It
# never opens, sources or executes anything it found there. A user can point
# their own view at any store directory they like; it is loaded only into
# their own processes (setuid programs are asserted to load no GL, see the
# feature header).
#
# Never fails the login: every problem is logged and ends in the system's
# tree. Configuration comes from the GL_NS_* variables the Nix wrapper sets
# (unconditionally, so a PAM environment cannot override them).

set -u

root=${GL_NS_ROOT:?}
gcroots=${GL_NS_GCROOTS:?}
peruser=${GL_NS_PERUSER:-/nix/var/nix/profiles/per-user}
store=${GL_NS_STORE:-/nix/store}
owner=${GL_NS_OWNER:-0}
have32=${GL_NS_32:-0}
mapped=" ${GL_NS_USERS:-} "

user=${1:-${PAM_USER:-}}

log() {
  logger -t gl-driver-select -- "${user:-?}: $*" 2>/dev/null || echo "gl-driver-select: ${user:-?}: $*" >&2
}

[ -n "$user" ] || exit 0
case $mapped in
  *" $user "*) ;;
  *) exit 0 ;; # not a mapped user: nothing to do, the namespace leaves them alone
esac

home=${GL_NS_HOME:-}
if [ -z "$home" ]; then
  home=$(getent passwd "$user" | cut -d: -f6)
fi

# A top-level store directory owned by root: what a built output is, and
# nothing a user can make without the daemon. (GL_NS_STORE / GL_NS_OWNER
# exist for tests/gl-namespace-select.sh; the wrapper pins them.)
valid() {
  case $1 in "$store"/*) ;; *) return 1 ;; esac
  [[ ${1#"$store"/} =~ ^[0-9a-z]{32}-[^/]+$ ]] && [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u -- "$1")" = "$owner" ]
}

resolve() {
  timeout 5 realpath -e -- "$1" 2>/dev/null
}

# The current generation: standalone home-manager's profile, then the
# legacy per-user location.
gen=
for p in ${home:+"$home/.local/state/nix/profiles/home-manager"} "$peruser/$user/home-manager"; do
  if t=$(resolve "$p") && valid "$t"; then
    gen=$t
    break
  fi
done

point() {
  sfx=$1
  sys=$root/system$sfx
  target=$sys
  if [ -n "$gen" ] && [ -L "$gen/graphics-driver$sfx" ]; then
    if t=$(resolve "$gen/graphics-driver$sfx") && valid "$t"; then
      target=$t
    else
      log "$gen/graphics-driver$sfx is not a store directory; using the system's driver"
    fi
  fi

  inst=$root/inst/$user
  if [ -L "$inst" ] || { [ -e "$inst" ] && [ ! -d "$inst" ]; }; then
    log "$inst is not a directory; left alone"
    return
  fi
  mkdir -p -m 0755 -- "$inst"
  ln -sfn -- "$target" "$inst/.tree$sfx.new" && mv -Tf -- "$inst/.tree$sfx.new" "$inst/tree$sfx"

  mkdir -p -m 0755 -- "$gcroots"
  if [ "$target" = "$sys" ]; then
    rm -f -- "$gcroots/$user$sfx"
  else
    ln -sfn -- "$target" "$gcroots/.$user$sfx.new" && mv -Tf -- "$gcroots/.$user$sfx.new" "$gcroots/$user$sfx"
  fi
  [ "$target" = "$sys" ] || log "driver$sfx: $target"
}

point ""
if [ "$have32" = 1 ]; then
  point "-32"
fi
exit 0
