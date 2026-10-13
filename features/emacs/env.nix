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
              through `sde64 -<cpu>`: temacs (dumps), bootstrap-emacs and
              emacs (byte/native compiles, via -sde wrapper scripts the
              Makefiles' EMACS settings point at), make-docfile,
              make-fingerprint and etags. SDE follows forks and execs, so
              what those start is emulated too. make itself cannot run under
              SDE: it keeps SIGCHLD blocked outside pselect, and Pin aborts
              ("received asynchronous signal 17 ... blocked by the
              application").

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
    e:
    let
      target =
        sdeTargets.${hostPlatform.gcc.arch or ""}
          or (throw "features/emacs: no SDE target for gcc.arch ${hostPlatform.gcc.arch or "(unset)"}");
      sde = "${pkgs.buildPackages.callPackage ./intel-sde.nix { }}/bin/sde64 -${target.cpu} --";
      bash = "${pkgs.buildPackages.bashNonInteractive}/bin/bash";
    in
    e.overrideAttrs (old: {
      # After nixpkgs' postPatch, which has made RUN_TEMACS `env -i ./temacs`.
      # --replace-fail, so an Emacs release that moves one of these fails the
      # build instead of silently running that program natively.
      postPatch = old.postPatch + ''
        for exe in emacs bootstrap-emacs; do
          cat > src/$exe-sde <<EOF
        #!${bash}
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
        Before nixpkgs' own postInstall, which runs $out/bin/emacs.

        The real binary goes to libexec, not lib: emacs finds the dumped
        native-lisp at ../lib/emacs/<version>/native-lisp from its own
        directory, and under SDE that directory is the real binary's.
        bin/emacs is a symlink to emacs-<version>, the file replaced here.
      */
      postInstall = ''
        launcher=$out/bin/$(readlink $out/bin/emacs)
        real=$out/libexec/$(basename $launcher)
        mv $launcher $real
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
      ''
      + old.postInstall;

      meta = old.meta // {
        broken = false;
      };
    });

  forHost = e: if buildPlatform.canExecute hostPlatform then e else withSde e;

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
  emacsPgtkBase = forHost (
    pkgs.emacs-pgtk.override {
      withNativeCompilation = true;
      withTreeSitter = true;
      withSystemd = true;
      withXwidgets = true;
    }
  );

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
  emacsNox = forHost (
    pkgs.emacs-nox.override {
      withNativeCompilation = true;
      withTreeSitter = true;
    }
  );
in
{
  inherit
    emacsPgtkBase
    emacsRolling
    emacsNox
    ;
}
