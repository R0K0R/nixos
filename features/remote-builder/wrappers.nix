{ config, lib, pkgs, ... }:

let
  cfg = config.my.remote-builder.client;

  flakeRef = "${cfg.flakePath}#${config.networking.hostName}";

  /*
    Generated per peer instead of written out by hand. The hand-written versions
    hardcoded `--flake /home/r0k0r/flakes/nixos#galaxybook4-pro360` in three
    places and the peer's own name in six, which meant a cloned host silently
    rebuilt the machine it was copied from -- the worst kind of failure, because
    it succeeds and does the wrong thing.

    Arguments are assembled as a LIST and joined, never interpolated as optional
    `\`-continued lines. An omitted optional line left a dangling backslash
    followed by a blank line, which terminates the command early -- the script
    still ran, but silently dropped "$@", so `nixos-rebuild-<peer> switch`
    rebuilt nothing and reported success.
  */
  mkScript =
    name: args:
    pkgs.writeScriptBin name ''
      #! /bin/sh
      exec ${lib.concatStringsSep " \\\n  " args} "$@"
    '';

  builderSpec =
    name: p:
    "ssh-ng://${p.sshUser}@${name} x86_64-linux ${cfg.sshKey} "
    + "${toString p.maxJobs} ${toString p.speedFactor} ${lib.concatStringsSep "," p.features}";

  /*
    ALWAYS pinned, never conditional, and both halves matter.

    Keeping cache.nixos.org means a peer whose BUILD-platform derivations are
    byte-identical to upstream still substitutes from Hydra rather than being
    rebuilt -- the reason the hand-written wrappers gave for omitting this flag.

    But omitting it does not mean "no override", it means "inherit the SYSTEM
    list", and that list can name a machine that is down. That is what made
    `nixos-rebuild-<peer>` sit in a retry loop against another peer even after
    that peer was removed from /etc/nix/machines: ssh-ng:// substituters use
    the same SSH store as builders and fail with the same message, so it reads
    as a builder problem and is not one. Naming the peer explicitly gets both
    properties.
  */
  substituterArgs =
    name: p:
    [ ''--option substituters "https://cache.nixos.org ssh-ng://${p.sshUser}@${name}"'' ];

  /*
    `--option builders` rather than the bare `--builders` flag: it reaches both
    the build step and (for nix-shell) the evaluation, and it matches what the
    nix-shell wrappers always used.

    IT DOES NOT MAKE THE NAME TRUE, and an earlier version of this comment
    wrongly claimed it did. nixos-rebuild-ng composes flake_eval_flags from its
    own argument group ONLY -- models.py:183, `vars(args_groups["flake_eval_flags"])`,
    with no `common_flags |` -- so no flag of any kind reaches the `nix eval`
    invocation in build_flake. That invocation is where import-from-derivation
    builds happen, and with nix-doom-emacs-unstraightened that means
    doom-intermediates. Such a build is dispatched by the daemon via nix.conf's
    `builders = @/etc/nix/machines`: the whole peer list, in speedFactor order,
    regardless of what this script says.

    So `nixos-rebuild-<peer>` restricts the BUILD phase to that peer and
    cannot restrict the EVAL phase at all. To genuinely exclude a peer, park it
    with `my.remote-builder.client.peers.<name>.enable = false`, which removes it
    from /etc/nix/machines.
  */
  # The local-eval path: evaluate HERE, build on the peer. Now the fallback of rebuildFor.
  localEvalFor = name: p: mkScript "nixos-rebuild-${name}-local-eval" (
    [ "nixos-rebuild" "--flake ${flakeRef}" "--option max-jobs 0" ''--option builders "${builderSpec name p}"'' ]
    ++ substituterArgs name p
  );

  /*
    nixos-rebuild-<evalWorker> (and plain nixos-rebuild, see defaultRebuild): EVALUATE
    ON THE PEER, build and activate as before. Evaluation is the slow, single-threaded
    half on this laptop: the same toplevel evaluates in ~19 s on victus-15 against
    ~65-72 s here in power-saver, ~39 s in performance (measured 2026-10-08; identical
    .drv every time). nixos-rebuild cannot do this -- even with --build-host it
    evaluates locally -- so:

      1. probe the peer (5 s ssh timeout)
      2. `nix flake archive --to` it: the checkout as it is, uncommitted edits included,
         plus every input, into the peer's store (~2 s; mostly already there)
      3. `nix eval ...toplevel.drvPath` ON the peer: ~19 s, writes the .drv closure there
      4. copy back only the .drv files this store lacks (see below): ~3 s when none
      5. build HERE with the wrapper's usual builders -- this store supplies the
         IntraISACross-tuned inputs; the peer can't substitute them itself
      6. activate as nixos-rebuild would: system profile + switch-to-configuration
         (switch/boot/test); `build` just prints the path

    Falls back to evaluating here when the peer is unreachable or a copy fails, for
    actions this does not handle (dry-build, edit, list-generations, ...), when extra
    arguments are given, or on --local-eval. A real evaluation or build ERROR is
    reported, not retried -- the same error would only take longer here.
  */
  # The remote path as a script named `scriptName`, evaluating on peer `name` and handing
  # anything it does not do (or cannot reach) to `local`.
  remoteEval = { scriptName, name, p, local, buildArgs }:
    let
      store = "ssh-ng://${p.sshUser}@${name}";
      attr = "nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel";
    in
    pkgs.writeShellScriptBin scriptName ''
      set -uo pipefail
      fallback() { echo "${scriptName}: $1 -- falling back to local evaluation" >&2; exec ${local} "$@"; }
      action="''${1:-}"
      case "$action" in
        --local-eval) shift; exec ${local} "$@" ;;
        switch|boot|test|build) ;;
        *) exec ${local} "$@" ;;
      esac
      [ "$#" -eq 1 ] || fallback "extra arguments (''${*:2}) are only understood by nixos-rebuild" "$@"

      as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

      ssh -o BatchMode=yes -o ConnectTimeout=5 ${name} true 2>/dev/null \
        || fallback "${name} is unreachable" "$@"

      echo ">> copying the flake to ${name}" >&2
      src=$(nix flake archive --json --to ${store} ${cfg.flakePath} | ${lib.getExe pkgs.jq} -r .path) \
        && [ -n "$src" ] || fallback "nix flake archive to ${name} failed" "$@"

      # EVALUATE there, BUILD here. A first version built on the peer too, and the peer
      # cannot substitute this host's IntraISACross-tuned outputs -- they live in this
      # store (no sshd here) -- so it began rebuilding the tuned world from scratch
      # (2026-10-08). The build stays as it was: dispatched from here, with this store
      # supplying the inputs.
      echo ">> evaluating on ${name}" >&2
      drv=$(ssh -o BatchMode=yes ${name} nix eval --raw "'$src#${attr}.drvPath'") \
        || { echo "${scriptName}: evaluation failed on ${name} (see above)" >&2; exit 1; }
      case "$drv" in /nix/store/*.drv) ;; *) echo "${scriptName}: no .drv from ${name}: $drv" >&2; exit 1 ;; esac

      echo ">> copying the derivations back" >&2
      # Only what is missing, and without walking the closure over the wire: `nix copy
      # --derivation --from` queried all ~23k paths across ssh one by one and took 190 s
      # to copy nothing (measured 2026-10-08). The peer lists the closure (one call,
      # local there), this host stats which are absent, and only those come over,
      # --no-recursive: 3.4 s with none missing, 17 s for ~1000 missing. -qR lists
      # dependencies first, so each path's references are already present.
      list=$(ssh -o BatchMode=yes ${name} nix-store -qR "'$drv'") \
        || fallback "listing the derivations on ${name} failed" "$@"
      missing=$(printf '%s\n' "$list" | while read -r p; do [ -e "$p" ] || printf '%s\n' "$p"; done)
      if [ -n "$missing" ]; then
        # no root needed: a trusted user may copy unsigned paths in; activation below is root's
        printf '%s\n' "$missing" | nix copy --no-recursive --no-check-sigs --from ${store} --stdin \
          || fallback "copying the derivations back from ${name} failed" "$@"
      fi

      echo ">> building" >&2
      out=$(nix build -L --no-link --print-out-paths "$drv^out" ${buildArgs}) \
        || { echo "${scriptName}: build failed (see above)" >&2; exit 1; }
      out=$(printf '%s\n' "$out" | tail -n1)
      case "$out" in /nix/store/*) ;; *) echo "${scriptName}: no store path from the build: $out" >&2; exit 1 ;; esac

      case "$action" in
        build) echo "$out" ;;
        test) as_root "$out/bin/switch-to-configuration" test ;;
        switch|boot)
          as_root nix-env -p /nix/var/nix/profiles/system --set "$out" \
            && as_root "$out/bin/switch-to-configuration" "$action" ;;
      esac
    '';

  shellFor = name: p: mkScript "nix-shell-${name}" (
    [ "nix-shell" "--option max-jobs 0" ''--option builders "${builderSpec name p}"'' ]
    ++ substituterArgs name p
  );

  localArgs = [
    "--option max-jobs ${toString cfg.localJobs}"
    "--option cores ${toString cfg.localCores}"
    ''--option substituters "https://cache.nixos.org"''
  ];

  localRebuild = mkScript "nixos-rebuild-local" (
    # Same --option reasoning as rebuildFor: an empty builder list has to apply
    # during evaluation too, or an IFD build escapes to /etc/nix/machines.
    [ "nixos-rebuild" "--flake ${flakeRef}" ''--option builders ""'' ] ++ localArgs
  );

  localShell = mkScript "nix-shell-local" (
    [ "nix-shell" ''--option builders ""'' ] ++ localArgs
  );
  remoteEvalFor = name: p: remoteEval {
    scriptName = "nixos-rebuild-${name}";
    inherit name p;
    # the peer wrapper's own build restriction: only this peer builds
    buildArgs = lib.concatStringsSep " " ([ "--option max-jobs 0" ''--option builders "${builderSpec name p}"'' ] ++ substituterArgs name p);
    local = "${localEvalFor name p}/bin/nixos-rebuild-${name}-local-eval";
  };

  /*
    Plain `nixos-rebuild` takes the same path when an evalWorker is set: bare
    switch/boot/test/build evaluate and build there; every other use -- other actions,
    --flake, --show-trace, any flag -- and every fallback is the real nixos-rebuild,
    untouched. hiPrio shadows the package's binary on PATH (and so under sudo's
    secure_path, /run/current-system/sw/bin).
  */
  defaultRebuild = lib.hiPrio (remoteEval {
    scriptName = "nixos-rebuild";
    name = cfg.evalWorker;
    p = cfg.peers.${cfg.evalWorker};
    local = lib.getExe' config.system.build.nixos-rebuild "nixos-rebuild";
    # plain nixos-rebuild builds with the system's own builders and substituters
    buildArgs = "";
  });

  # Only the evalWorker peer evaluates remotely (and keeps the local-eval path as its
  # fallback, also runnable by name); every other peer's wrapper evaluates here.
  rebuildFor = name: p: if name == cfg.evalWorker then remoteEvalFor name p else localEvalFor name p;
  renamedTo = n: drv: pkgs.runCommandLocal n { } "mkdir -p $out/bin; ln -s ${drv}/bin/* $out/bin/${n}";
in
lib.mkIf (cfg.enable && cfg.wrappers.enable) {
  assertions = [{
    assertion = cfg.evalWorker == null || (cfg.peers ? ${toString cfg.evalWorker} && cfg.peers.${cfg.evalWorker}.enable);
    message = "my.remote-builder.client.evalWorker = ${toString cfg.evalWorker}: not an enabled peer";
  }];

  environment.systemPackages =
    [ localRebuild localShell ]
    ++ lib.mapAttrsToList (name: p: renamedTo "nixos-rebuild-${name}" (rebuildFor name p)) cfg.peers
    ++ lib.optional (cfg.evalWorker != null) (localEvalFor cfg.evalWorker cfg.peers.${cfg.evalWorker})
    ++ lib.optional (cfg.evalWorker != null) defaultRebuild
    ++ lib.mapAttrsToList shellFor cfg.peers;
}
