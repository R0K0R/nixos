/*
  Handover credentials: how someone the laptop is lent to gets in, and how
  that stops.

  THE DESIGN, and the ones it beat:

    * Autologin into the kiosk (greetd initial_session). No secret at all,
      which is the problem on a SHARED machine: anyone who opens the lid --
      or reboots it -- is the guest, and an expiry check has nothing to ask.
      Ruled out.
    * A fixed password in the registry (passwordSecret). A secret that
      outlives every lending: the third borrower knows the first one's
      password, and revoking it is a re-encrypt + switch. Refused by the
      registry for this type.
    * One random passphrase per LENDING, issued by an admin on the machine
      itself. This one:

        sudo handover issue <user> [--for "8 hours" | --until "2026-11-01 18:00"]

      generates a fresh passphrase (16 characters from a 32-letter alphabet,
      80 bits; printed ONCE on the admin's terminal and stored nowhere),
      writes its yescrypt hash to <stateDir>/<user>.hash, applies it to
      /etc/shadow at once (usermod -p), and records the lending's end as an
      epoch in <stateDir>/<user>.until. Before that it ends any session the
      account still has, so the new borrower never inherits the previous
      one's tmpfs home. `handover revoke <user>` locks the account
      (hash "!"), deletes the deadline and ends its sessions;
      `handover status` shows what is issued.

  WHERE THE END IS ENFORCED -- three layers, each independent:

    1. The deadline, at PAM account time: an account rule (pam_exec, before
       pam_unix) on greetd and login refuses a handover user whose .until is
       missing, unreadable, malformed or past. Fail-closed: a freshly created
       account with nothing issued cannot log in, and neither can one whose
       state directory went missing.
    2. The session already running at the deadline: issue arms a transient
       systemd timer (realtime, OnCalendar -- a monotonic one would not
       count the hours the lid was shut) that runs `handover revoke`.
       Transient units die with the boot; after a reboot there is no session
       left to end and layer 1 refuses new ones.
    3. A hard ceiling from the registry: `handover.expires = "YYYY-MM-DD"`
       in the user file becomes users.users.<n>.expires, the shadow expiry
       pam_unix checks for EVERY service. issue refuses a deadline past it.
       (NixOS writes that field only when it is set: removing the key later
       leaves the old date in /etc/shadow until `chage -E -1 <user>`.)

  WHY THE HASH LIVES IN A FILE (hashedPasswordFile) AND IN /etc/shadow.
  With users.mutableUsers = false (victus-15) every activation rewrites
  /etc/shadow from hashedPasswordFile, so the file must hold the current
  hash or the next switch would undo an issue. With mutableUsers = true the
  file only seeds a NEW account, and usermod is what counts. issue writes
  both, so either mode agrees. On an impermanent host /etc/shadow is rebuilt
  at every boot, the account is "new" each time, and the hash is read from
  the file -- so the file lives directly under persistRoot (the users
  activation runs before impermanence's bind mounts exist; the same reason
  the impermanence docs give for password files). An activation snippet
  ordered before `users` writes a locked "!" hash for an account that has
  none, so the users script never warns about a missing file and a new
  account starts locked.

  WHAT A SHARED MACHINE SEES. <stateDir> is 0700 root, the files 0600; the
  passphrase itself is never written down. Other local users see neither.
  Nothing secret is in the repo or the store: the store holds the scripts
  and the list of handover account names, nothing else.

  Gated on some account being a handover (registry type "handover"); every
  real host has none, so none of this is in their toplevels.
*/
{ config, lib, pkgs, ... }:

let
  hand = lib.filterAttrs (_: u: u.handover != null) config.my.users;
  names = lib.attrNames hand;

  imp = config.my.impermanence;
  stateDir = if imp.enable then "${imp.persistRoot}/var/lib/handover" else "/var/lib/handover";

  pamPkg = config.security.pam.package;

  # user) ceiling='YYYY-MM-DD' ;; -- the tool turns it into the last second
  # of that day, local time.
  ceilings = lib.concatMapStrings (n: ''
    ${n}) ceiling=${lib.escapeShellArg (if hand.${n}.handover.expires == null then "" else hand.${n}.handover.expires)} ;;
  '') names;
  userCase = lib.concatStringsSep "|" names;

  /*
    PAM account check. Runs as root (seteuid; greetd's worker and login are
    root anyway). Non-handover users pass without touching the disk.
  */
  pamCheck = pkgs.writeShellScript "handover-pam-account" ''
    case "''${PAM_USER-}" in
      ${userCase}) ;;
      *) exit 0 ;;
    esac
    f=${stateDir}/"$PAM_USER".until
    [ -r "$f" ] || exit 1
    IFS= read -r until < "$f" || exit 1
    case "$until" in ""|*[!0-9]*) exit 1 ;; esac
    [ "$(${pkgs.coreutils}/bin/date +%s)" -lt "$until" ]
  '';

  tool = pkgs.writeShellScriptBin "handover" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.shadow pkgs.mkpasswd config.systemd.package pkgs.gnugrep ]}
    dir=${stateDir}
    self=$(readlink -f "$0")

    usage() {
      cat >&2 <<'EOF'
    usage: handover issue <user> [--for "<duration>" | --until "<date>"]
           handover revoke <user>
           handover status [<user>]
      duration/date: anything `date -d` reads ("8 hours", "2026-11-01 18:00").
      Default: --for "24 hours". Handover accounts here: ${lib.concatStringsSep " " names}
    EOF
      exit 2
    }

    known() {
      case "$1" in
        ${userCase}) ;;
        *) echo "handover: $1 is not a handover account on this host" >&2; exit 2 ;;
      esac
    }

    root() {
      [ "$(id -u)" = 0 ] || { echo "handover: must run as root" >&2; exit 1; }
    }

    end_sessions() {
      loginctl terminate-user "$1" 2>/dev/null || true
    }

    lock() {
      local u=$1
      umask 077
      printf '!\n' > "$dir/$u.hash.tmp"
      mv "$dir/$u.hash.tmp" "$dir/$u.hash"
      usermod -p '!' "$u"
      rm -f "$dir/$u.until"
      systemctl stop "handover-expire-$u.timer" 2>/dev/null || true
    }

    cmd=''${1:-}
    [ $# -gt 0 ] && shift
    case "$cmd" in
      issue)
        root
        [ $# -ge 1 ] || usage
        u=$1; shift
        known "$u"
        spec="now + 24 hours"
        while [ $# -gt 0 ]; do
          case "$1" in
            --for) [ $# -ge 2 ] || usage; spec="now + $2"; shift 2 ;;
            --until) [ $# -ge 2 ] || usage; spec=$2; shift 2 ;;
            *) usage ;;
          esac
        done
        until=$(date -d "$spec" +%s) || { echo "handover: cannot read the time \"$spec\"" >&2; exit 2; }
        now=$(date +%s)
        [ "$until" -gt "$now" ] || { echo "handover: $(date -d "@$until") is not in the future" >&2; exit 2; }
        ceiling=""
        case "$u" in
          ${ceilings}
        esac
        if [ -n "$ceiling" ]; then
          max=$(date -d "$ceiling 23:59:59" +%s)
          if [ "$until" -gt "$max" ]; then
            echo "handover: $u expires $ceiling (registry handover.expires); cannot issue past it" >&2
            exit 1
          fi
        fi

        mkdir -p -m 0700 "$dir"
        # The previous borrower's session (and with it the tmpfs home) ends
        # before the new passphrase exists.
        end_sessions "$u"
        lock "$u"

        # pipefail off inside: tr dies of SIGPIPE when head has its 16.
        pass=$(set +o pipefail; tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' < /dev/urandom | head -c 16 | sed 's/..../&-/g; s/-$//')
        hash=$(printf '%s' "$pass" | mkpasswd -m yescrypt --stdin)
        umask 077
        printf '%s\n' "$hash" > "$dir/$u.hash.tmp"
        mv "$dir/$u.hash.tmp" "$dir/$u.hash"
        usermod -p "$hash" "$u"
        printf '%s\n' "$until" > "$dir/$u.until.tmp"
        mv "$dir/$u.until.tmp" "$dir/$u.until"

        systemd-run --quiet --collect --unit="handover-expire-$u" \
          --on-calendar="$(date -d "@$until" '+%Y-%m-%d %H:%M:%S')" \
          --timer-property=AccuracySec=1s \
          "$self" revoke "$u" >/dev/null

        echo "account:    $u"
        echo "passphrase: $pass"
        echo "valid until $(date -d "@$until")"
        echo "(shown once; \`handover issue\` again for a new one, \`handover revoke $u\` to end it now)"
        ;;
      revoke)
        root
        [ $# -eq 1 ] || usage
        known "$1"
        mkdir -p -m 0700 "$dir"
        lock "$1"
        end_sessions "$1"
        echo "handover: $1 locked, sessions ended"
        ;;
      status)
        root
        for u in ''${1:-${lib.concatStringsSep " " names}}; do
          known "$u"
          if [ -r "$dir/$u.until" ] && IFS= read -r until < "$dir/$u.until" && [ "$until" -gt "$(date +%s)" ]; then
            state="issued, valid until $(date -d "@$until")"
          else
            state="not issued (locked)"
          fi
          n=$(loginctl list-sessions --no-legend 2>/dev/null | grep -c " $u " || true)
          echo "$u: $state; $n session(s)"
        done
        ;;
      *) usage ;;
    esac
  '';
in
{
  config = lib.mkIf (hand != { }) {
    environment.systemPackages = [ tool ];

    users.users = lib.genAttrs names (n: {
      hashedPasswordFile = "${stateDir}/${n}.hash";
      inherit (hand.${n}.handover) expires;
    });

    system.activationScripts.handover-credentials = ''
      mkdir -p -m 0700 ${stateDir}
      chmod 0700 ${stateDir}
      for u in ${lib.escapeShellArgs names}; do
        if [ ! -e ${stateDir}/"$u".hash ]; then
          (umask 077; printf '!\n' > ${stateDir}/"$u".hash)
        fi
      done
    '';
    system.activationScripts.users.deps = [ "handover-credentials" ];

    /*
      The services whose login leads to the pinned session (kiosk.nix): the
      greeter and the VT login. sshd and su refuse kiosk users outright.
      nixpkgs' greetd service has no rule stack of its own -- its account
      phase is `include login` -- so the login rule covers it; the greetd
      rule only applies if a later nixpkgs gives greetd default rules
      (asserted below that one of the two holds).
    */
    security.pam.services = lib.genAttrs ([ "login" ] ++ lib.optional config.services.greetd.enable "greetd") (svc: {
      rules.account.handover-deadline = lib.mkIf config.security.pam.services.${svc}.useDefaultRules {
        order = config.security.pam.services.${svc}.rules.account.unix.order - 10;
        control = "required";
        modulePath = "${pamPkg}/lib/security/pam_exec.so";
        args = [ "quiet" "seteuid" "${pamCheck}" ];
      };
    });

    assertions = [
      {
        assertion =
          let
            g = config.security.pam.services.greetd;
          in
          !config.services.greetd.enable || g.useDefaultRules || (g.rules.account.login.modulePath or "") == "login";
        message = "handover.nix: the greetd PAM service neither has default rules nor includes login's account stack; the handover deadline would not be checked there.";
      }
    ]
    ++ lib.concatMap (n: [
      {
        assertion = config.my.users.${n}.passwordSecret == null && config.my.users.${n}.hashedPasswordFile == null;
        message = "my.users.${n}: a handover account's password is issued per lending (`handover issue`), not declared; drop passwordSecret/hashedPasswordFile.";
      }
      {
        assertion = config.my.users.${n}.kiosk != null;
        message = "my.users.${n}: a handover account needs a kiosk session -- the credential is for the pinned program, not a desktop.";
      }
    ]) names;
  };
}
