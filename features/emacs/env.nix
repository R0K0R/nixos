# Shared custom Emacs build; used by doom-config.nix.
{ pkgs, inputs }:

let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv) buildPlatform hostPlatform;

  /*
    Under IntraISACross the build machine may lack the host's ISA extensions
    (victus' Zen 3 and yulee's Zen 5 both miss part of Meteor Lake), and
    Emacs' build runs what it compiles: temacs byte- and native-compiles the
    bundled Lisp and dumps itself into the .pdmp files, all with the tuned
    code. The nixpkgs fork marks such a build broken. Here it is made to work
    instead, with Intel SDE emulating the host CPU:

      build   every recipe that runs a program the build compiled goes
              through `sde64 -<cpu>`: temacs (dumps), make-docfile,
              make-fingerprint, etags, and bootstrap-emacs/emacs for what is
              not compiling Lisp (autoloads, unidata, leim, manuals). SDE
              follows forks and execs, so what those start is emulated too.
              make itself cannot run under SDE: it keeps SIGCHLD blocked
              outside pselect, and Pin aborts ("received asynchronous signal
              17 ... blocked by the application").

      compile byte- and native-compiling the Lisp -- nearly all of the build
              under NATIVE_FULL_AOT -- does not need to RUN host code, only to
              emit it, so it runs natively on a generic build of the same
              Emacs with the same features (`compiler` below). The Makefiles'
              EMACS points at -sde wrappers that send any batch-*-compile
              there. A .eln only has to carry the tuned build's comp-abi-hash
              (checked when it loads) and sit in its comp-native-version-dir;
              both are plain variables, set from the tuned binary's own values
              (probed once, under SDE). The hash also covers
              system-configuration (the tuned build, configured as a cross
              build, says x86_64-unknown-linux-gnu, the generic one
              x86_64-pc-linux-gnu) and system-configuration-options (they
              differ by --prefix and the cross build's --build/--host), so
              the parts that matter are compared instead: the primitives'
              signatures in order, the configured features and the .eln
              naming must match, or the build fails.
              libgccjit gets -march/-mtune for the host. nixpkgs' postInstall
              (site-start, trampolines) compiles the same way.

      run     bin/emacs becomes a launcher that execs the real binary under
              SDE when /proc/cpuinfo lacks one of the host's extensions, and
              directly otherwise. Every later build that runs this Emacs
              (elisp packages' byte/native compiles, the emacsWithPackages
              wrapper, Unstraightened's IFD and Doom profile) then works on any
              builder with no change of its own. On gb4 it costs a read of
              /proc/cpuinfo per start and SDE's ~35M in the closure.

    The launcher and SDE use the build platform's bash and glibc: they are what
    runs before emulation starts. EMACS_UNDER_SDE marks a process tree that is
    already emulated, so an Emacs started from an emulated one does not stack
    a second SDE.

    The flag list is the part of -march=<cpu> the kernel reports in
    /proc/cpuinfo; hreset, kl, widekl, pconfig, ptwrite and sgx are enabled
    by gcc but not reported, and gcc emits them only through intrinsics.
  */
  sdeTargets = {
    meteorlake = {
      cpu = "mtl";
      flags = [
        "adx"
        "aes"
        "avx"
        "avx2"
        "avx_vnni"
        "bmi1"
        "bmi2"
        "clflushopt"
        "clwb"
        "cx16"
        "f16c"
        "fma"
        "fsgsbase"
        "fxsr"
        "gfni"
        "abm"
        "mmx"
        "movbe"
        "movdir64b"
        "movdiri"
        "pclmulqdq"
        "pku"
        "popcnt"
        "3dnowprefetch"
        "rdpid"
        "rdrand"
        "rdseed"
        "lahf_lm"
        "serialize"
        "sha_ni"
        "sse"
        "sse2"
        "pni"
        "ssse3"
        "sse4_1"
        "sse4_2"
        "vaes"
        "vpclmulqdq"
        "waitpkg"
        "xsave"
        "xsavec"
        "xsaveopt"
        "xsaves"
      ];
    };
  };

  withSde =
    e: compiler:
    let
      arch = hostPlatform.gcc.arch;
      target = sdeTargets.${arch} or (throw "features/emacs: no SDE target for gcc.arch ${arch}");
      sde = "${pkgs.buildPackages.callPackage ./intel-sde.nix { }}/bin/sde64 -${target.cpu} --";
      bash = "${pkgs.buildPackages.bashNonInteractive}/bin/bash";

      # TUNED_TOP: the tuned build's source tree. TUNED_ELN_ROOT: the
      # native-lisp directory the .eln files go to (default: the tree's).
      compileForHost = pkgs.buildPackages.writeScript "emacs-compile-for-host" ''
        #!${bash}
        set -e
        abi=$TUNED_TOP/src/.tuned-abi
        if [[ ! -s $abi ]]; then
          probe='(princ (format "%s\n%s\n%s\n%s\n" comp-abi-hash comp-native-version-dir
            (md5 (concat emacs-version system-configuration-features
                         (mapconcat (function comp--subr-signature) comp-subr-list "")))
            (comp-el-to-eln-rel-filename "'"$TUNED_TOP"'/lisp/subr.el")))'
          tuned=$(${sde} "$TUNED_TOP/src/bootstrap-emacs" -batch --eval "$probe")
          generic=$(${compiler}/bin/emacs -batch --eval "$probe")
          if [[ $(tail -n 2 <<<"$tuned") != "$(tail -n 2 <<<"$generic")" ]]; then
            echo "emacs-compile-for-host: ${compiler} cannot compile for this build" >&2
            echo "  (md5 of version, features and primitive signatures; .eln name of subr.el) differ:" >&2
            echo "  tuned:   $(tail -n 2 <<<"$tuned" | tr '\n' ' ')" >&2
            echo "  generic: $(tail -n 2 <<<"$generic" | tr '\n' ' ')" >&2
            exit 1
          fi
          head -n 2 <<<"$tuned" > "$abi.$$"
          mv "$abi.$$" "$abi"
        fi
        { read -r hash; read -r vdir; } < "$abi"
        first=$1
        shift
        exec ${compiler}/bin/emacs "$first" --eval "(setq comp-abi-hash \"$hash\"
          comp-native-version-dir \"$vdir\"
          native-comp-compiler-options '(\"-march=${arch}\" \"-mtune=${arch}\")
          native-comp-eln-load-path (append (butlast native-comp-eln-load-path)
                                            (list \"''${TUNED_ELN_ROOT:-$TUNED_TOP/native-lisp/}\")))" "$@"
      '';
    in
    e.overrideAttrs (old: {
      # After nixpkgs' postPatch, which has made RUN_TEMACS `env -i ./temacs`.
      # --replace-fail, so an Emacs release that moves one of these fails the
      # build instead of silently running that program natively.
      postPatch = old.postPatch + ''
        for exe in emacs bootstrap-emacs; do
          cat > src/$exe-sde <<EOF
        #!${bash}
        case " \$* " in
          *batch-byte+native-compile*|*batch-native-compile*|*batch-byte-compile*)
            TUNED_TOP=\$(cd "\$(dirname "\$0")/.." && pwd) exec ${compileForHost} "\$@" ;;
        esac
        exec ${sde} "\''${0%-sde}" "\$@"
        EOF
          chmod +x src/$exe-sde
        done

        substituteInPlace src/Makefile.in \
          --replace-fail 'RUN_TEMACS = env -i ./temacs' 'RUN_TEMACS = env -i ${sde} ./temacs' \
          --replace-fail '$(libsrc)/make-docfile -d' '${sde} $(libsrc)/make-docfile -d' \
          --replace-fail '$(AM_V_at)$(MAKE_PDUMPER_FINGERPRINT) $@' '$(AM_V_at)${sde} $(MAKE_PDUMPER_FINGERPRINT) $@' \
          --replace-fail '$(bootstrap_exe)"' '$(bootstrap_exe)-sde"' \
          --replace-fail 'EMACS="../src/emacs$(EXEEXT)"' 'EMACS="../src/emacs-sde"'
        substituteInPlace lisp/Makefile.in leim/Makefile.in lib-src/Makefile.in \
          --replace-fail 'EMACS = ../src/emacs''${EXEEXT}' 'EMACS = ../src/emacs-sde'
        substituteInPlace admin/unidata/Makefile.in admin/grammars/Makefile.in \
          --replace-fail 'EMACS = ''${top_builddir}/src/emacs' 'EMACS = ''${top_builddir}/src/emacs-sde'
        substituteInPlace doc/misc/Makefile.in \
          --replace-fail 'EMACS = ''${abs_top_builddir}/src/emacs' 'EMACS = ''${abs_top_builddir}/src/emacs-sde'
        # The sanity check and the installed .pdmp's fingerprint name.
        substituteInPlace Makefile.in \
          --replace-fail 'src/emacs''${EXEEXT} --' 'src/emacs-sde --'
        # etags, for the "tags" install target: every TAGS recipe.
        substituteInPlace lisp/Makefile.in \
          --replace-fail 'xargs $(XARGS_LIMIT) "''${ETAGS}"' 'xargs $(XARGS_LIMIT) ${sde} "''${ETAGS}"'
        find . -name Makefile.in -exec sed -i -E \
          's#^(\t(\$\(AM_V_GEN\))?)(\$\{ETAGS\}|\$\(ETAGS\)|\./etags) #\1${sde} \3 #' {} +
      '';

      /*
        The real binary goes to libexec, not lib: emacs finds the dumped
        native-lisp at ../lib/emacs/<version>/native-lisp from its own
        directory, and under SDE that directory is the real binary's.
        bin/emacs is a symlink to emacs-<version>, the file replaced here.

        nixpkgs' postInstall runs $out/bin/emacs only to compile (site-start,
        trampolines), so until it is done that name is compileForHost aimed at
        $out's native-lisp. The launcher replaces it afterwards, and the last
        step loads a non-preloaded library's .eln in the tuned binary: a .eln
        it refuses (ABI hash, name) fails the build here, not at first use.
      */
      postInstall = ''
        launcher=$out/bin/$(readlink $out/bin/emacs)
        real=$out/libexec/$(basename $launcher)
        mv $launcher $real
        versionDir=$(ls $out/share/emacs | grep -v site-lisp | head -n 1)
        cat > $launcher <<EOF
        #!${bash}
        TUNED_TOP=$PWD TUNED_ELN_ROOT=$out/lib/emacs/$versionDir/native-lisp/ exec ${compileForHost} "\$@"
        EOF
        chmod +x $launcher
      ''
      + old.postInstall
      + ''
        cat > $launcher <<EOF
        #!${bash}
        if [[ -z \''${EMACS_UNDER_SDE-} ]]; then
          while IFS= read -r line; do
            if [[ \$line == flags* ]]; then flags=" \''${line#*:} "; break; fi
          done < /proc/cpuinfo
          for f in ${lib.concatStringsSep " " target.flags}; do
            if [[ \$flags != *" \$f "* ]]; then
              export EMACS_UNDER_SDE=1
              exec ${sde} $real "\$@"
            fi
          done
        fi
        exec -a "\$0" $real "\$@"
        EOF
        chmod +x $launcher

        $out/bin/emacs -batch --eval "(progn (require 'calc)
          (unless (native-comp-function-p (symbol-function 'calc))
            (error \"calc did not load from its .eln\")))"
      '';

      meta = old.meta // {
        broken = false;
      };
    });

  # The package by name, so the generic compiler can be the same package with
  # the same flags from buildPackages.
  forHost =
    name: args:
    let
      e = pkgs.${name}.override args;
    in
    if buildPlatform.canExecute hostPlatform then
      e
    else
      withSde e (pkgs.buildPackages.${name}.override args);

  /*
    Unstable `emacs-pgtk` + xwidgets, against whatever WebKit nixpkgs ships.

    This used to pin webkitgtk from nixos-22.11 (2.38), because Emacs's
    configure once demanded `webkit2gtk-4.1 < 2.41.92'.  Emacs 31 asks only
    for `>= 2.12' -- the upper bound is gone from configure.ac -- so the pin
    now buys a 2022 engine and nothing else.  It cost: the preview stuttered
    on documents Firefox rendered smoothly, and tinymist's partial rendering
    drew the last page over the first, neither of which reproduces on a
    current WebKit.
  */
  emacsPgtkBase = forHost "emacs-pgtk" {
    withNativeCompilation = true;
    withTreeSitter = true;
    withSystemd = true;
    withXwidgets = true;
  };

  # nix-doom-emacs-unstraightened builds every Doom package (vterm included)
  # via `emacsPackagesFor emacsRolling`, matched to this exact Emacs build.
  emacsRolling = emacsPgtkBase;

  /*
    Terminal-only Emacs for headless hosts (victus-15 has no display manager or
    compositor -- its nvidia driver is there for CUDA). emacsPgtkBase would
    still *run* under `-nw`, but it drags GTK, WebKit 2.38 and xwidgets into
    the closure of a machine that can never display them, and that machine also
    builds. Native compilation and tree-sitter are kept: both are useful in a
    terminal, and TREESIT_GRAMMAR_DIR (doom-config.nix) feeds the same
    Nix-provided grammars either way.
  */
  emacsNox = forHost "emacs-nox" {
    withNativeCompilation = true;
    withTreeSitter = true;
  };
in
{
  inherit
    emacsPgtkBase
    emacsRolling
    emacsNox
    ;
}
