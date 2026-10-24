/*
  BUILD-TIME half of "no privileged wrapper may load GL"
  (docs/multiuser-design.md, trust section; features/session/gl-namespace).

  Under gl-namespace a mapped user's /run/opengl-driver is a tree they
  control. A setuid, setgid or setcap program started in their session that
  loads anything from there runs their code with its privileges. Evaluation
  can only see a wrapper's derivation and its declared inputs (the nixos
  half asserts on those); what a binary actually loads is its RUNTIME
  closure, which is known only after the build. This derivation reads it.

  For every enabled privileged wrapper in security.wrappers (minus
  my.gl-namespace.allowPrivilegedGL), over the wrapper source's full runtime
  closure (exportReferencesGraph):
    rpath     an ELF whose RUNPATH/RPATH names /run/opengl-driver
              (patchelf --print-rpath) -- the libraries it links come from
              the user's tree;
    embeds    an ELF that contains the string elsewhere -- a baked dlopen
              directory (libglvnd's vendor dir, the Vulkan loader's ICD
              dir, libva's driver dir);
    package   a closure member that is a GL stack package by name (mesa,
              libglvnd, vulkan-loader, ...), whatever it embeds.
  Any hit fails the build with a per-wrapper report. Non-ELF files that
  mention the path (docs, scripts) are listed as notes, not failures.

  A BUILD, so: never in the toplevel (system.checks would put it there) and
  never on this laptop -- flake output setuidGlChecks.<host>, run with
  `nix build` on the builders; checks.<system> carries it only for hosts
  where gl-namespace is active. Built with buildPackages: the check's own
  tools need no target-tuned build.
*/
{ lib, pkgs, config, hostName }:

let
  bp = pkgs.buildPackages;
  allow = config.my.gl-namespace.allowPrivilegedGL or { };
  ws = lib.filterAttrs (
    n: w: w.enable && (w.setuid || w.setgid || w.capabilities != "") && !(allow ? ${n})
  ) config.security.wrappers;
  glNames = "mesa|libglvnd|libGL|libgbm|vulkan-loader|libva|libvdpau|ocl-icd|nvidia-x11|egl-wayland";
in
bp.runCommand "setuid-no-gl-${hostName}"
  {
    __structuredAttrs = true;
    wrappers = lib.mapAttrs (_: w: toString w.source) ws;
    exportReferencesGraph = lib.mapAttrs' (n: w: lib.nameValuePair "closure-${n}" [ w.source ]) ws;
    allowed = allow;
    nativeBuildInputs = [
      bp.jq
      bp.patchelf
      bp.gnugrep
    ];
  }
  ''
    attrs=''${NIX_ATTRS_JSON_FILE:-.attrs.json}
    report=$(mktemp)
    fail=0
    while IFS=$'\t' read -r name src; do
      hits=()
      notes=()
      mapfile -t paths < <(jq -r --arg k "closure-$name" '.[$k][].path' "$attrs")
      for p in "''${paths[@]}"; do
        base=''${p#/nix/store/}
        base=''${base#*-}
        if [[ $base =~ ^(${glNames})(-[0-9]|-x86_64|-i686|$) ]]; then
          hits+=("package  $p")
        fi
      done
      while IFS= read -r -d "" f; do
        if [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then
          rp=$(patchelf --print-rpath "$f" 2>/dev/null || true)
          case ":$rp:" in
            *:/run/opengl-driver*) hits+=("rpath    $f ($rp)") ;;
            *) hits+=("embeds   $f") ;;
          esac
        else
          notes+=("mentions $f")
        fi
      done < <(grep -rlFZ /run/opengl-driver -- "''${paths[@]}" 2>/dev/null || true)
      {
        echo "== $name -> $src (''${#paths[@]} closure paths)"
        for h in "''${hits[@]}"; do echo "  FAIL $h"; done
        for n in "''${notes[@]}"; do echo "  note $n"; done
      } >> "$report"
      if [ ''${#hits[@]} -gt 0 ]; then fail=1; fi
    done < <(jq -r '.wrappers | to_entries[] | "\(.key)\t\(.value)"' "$attrs")

    jq -r '.allowed | to_entries[] | "== \(.key): allowed (\(.value))"' "$attrs" >> "$report"
    cat "$report"
    if [ $fail = 1 ]; then
      echo "privileged wrappers on ${hostName} load GL: see FAIL lines above" >&2
      exit 1
    fi
    cp "$report" "$out"
  ''
