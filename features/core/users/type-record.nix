/*
  The deployed type, recorded per account, and the switch that refuses a
  dangerous change to it.

  A registry type is a promise about state that outlives any one generation:
  a persistent home, a nix profile, home-manager generations. Changing a
  user's type in registry/users/ is one line, and what it does to that state
  is not visible in the diff -- persistent -> tmpfs hides the whole home
  under an empty tmpfs at the next login; member -> untrusted drops his
  session and grants. So the type that was actually deployed is recorded in
  /var/lib/nixos-users/<user>.type as one line, "<type> <home> <nix>", and a
  switch to a configuration that moves a user dangerously away from it is
  refused unless his registry file says, in so many words,

    acceptTypeChange = "<old type>-><new type>";

  WHAT IS DANGEROUS is decided in exactly one place, lib/registry.nix
  `transition` (home leaving persistent, nix or type rank going down). That
  is pure Nix; the shell below does not re-implement it. The registry
  enumerates every recorded line the CURRENT record may follow -- itself,
  every safe predecessor, and, when acceptTypeChange is set, the predecessors
  it names -- and the script only asks whether the file's line is in that
  list. An unreadable or unknown line (a type since renamed, a hand edit) is
  therefore refused too, unless acceptTypeChange names its type.

  WHERE IT REFUSES. system.preSwitchChecks: switch-to-configuration runs it
  for switch, boot and test before touching the bootloader or activating, so
  a refused change changes nothing. The activation snippet then WRITES the
  record (after the users snippet, so the account exists). It checks again
  and declines to write on refusal -- the case of booting a generation that
  never went through a switch, e.g. an older one picked from the boot menu:
  booting cannot be refused, but the record does not advance, so the next
  switch still sees the real deployed type.

  INERT WHEN NOTHING CHANGED. A missing (or empty) record is written without
  a check (first deployment), and a record equal to the current line is a
  no-op.
  acceptTypeChange is consent to ONE transition and harmless afterwards: once
  the new type is recorded, the old->new pair no longer occurs.

  OPT-IN. The check and the snippet are part of the toplevel, so turning this
  on is itself a (cheap) system change; off by default so existing hosts
  stay identical until someone decides to start recording.
*/
{ config, lib, ... }:

let
  cfg = config.my.registry.recordTypes;
  dir = "/var/lib/nixos-users";
  recorded = lib.filterAttrs (_: u: u.typeRecord != null) config.my.users;

  /*
    One block per account. Sets `refused=1` for a refusal; in record mode
    writes the new line when admissible. The case patterns are quoted, so a
    line is compared literally.
  */
  perUser =
    record: n: u:
    let
      r = u.typeRecord;
      file = "${dir}/${n}.type";
      newType = lib.head (lib.splitString " " r.current);
    in
    ''
      rec_file=${lib.escapeShellArg file}
      ok=1
      old=""
      if [ -s "$rec_file" ]; then
        # read, not head: the pre-switch check runs with whatever PATH
        # switch-to-configuration has, so it uses builtins only.
        IFS= read -r old < "$rec_file" || true
        case "$old" in
          ${lib.concatMapStringsSep "|" lib.escapeShellArg r.admissible}) ok=1 ;;
          *) ok=0 ;;
        esac
        ${lib.optionalString (r.accept != null) ''
          if [ "$ok" = 0 ] && [ "''${old%% *}->"${lib.escapeShellArg newType} = ${lib.escapeShellArg r.accept} ]; then
            ok=1
          fi
        ''}
      fi
      if [ "$ok" = 1 ]; then
        ${lib.optionalString record ''
          if [ "$old" != ${lib.escapeShellArg r.current} ]; then
            mkdir -p -m 0755 ${dir}
            printf '%s\n' ${lib.escapeShellArg r.current} > "$rec_file.tmp"
            mv "$rec_file.tmp" "$rec_file"
          fi
        ''}
        :
      else
        echo "nixos-users: refusing to move ${n} from \"$old\" to \"${r.current}\" (dangerous transition)." >&2
        echo "nixos-users: if intended, set acceptTypeChange = \"''${old%% *}->${newType}\"; in registry/users/${n}.nix" >&2
        refused=1
      fi
    '';

  script =
    record:
    ''
      refused=0
    ''
    + lib.concatStrings (lib.mapAttrsToList (perUser record) recorded);
in
{
  options.my.registry.recordTypes.enable = lib.mkEnableOption ''
    recording each registry account's deployed type in
    /var/lib/nixos-users/<user>.type and refusing a switch that moves an
    account dangerously away from it (persistent -> tmpfs home, nix or type
    demotion) unless the user's registry file carries the matching
    acceptTypeChange = "<old>-><new>"'';

  config = lib.mkIf (cfg.enable && recorded != { }) {
    system.preSwitchChecks.nixos-user-types = script false + ''
      if [ "$refused" != 0 ]; then
        exit 1
      fi
    '';

    system.activationScripts.nixos-user-types = {
      deps = [ "users" ];
      text = script true + ''
        if [ "$refused" != 0 ]; then
          _localstatus=1
        fi
      '';
    };
  };
}
