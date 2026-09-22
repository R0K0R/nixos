{
  lib,
  stdenvNoCC,
  makeWrapper,
  bubblewrap,
  xdg-utils,
  bash,
  coreutils,
  socat,
  src,
  version,
}:

/*
  Claude Science (beta), the local research daemon.

  Not repackaged the way ../claude-desktop is. That one is an Electron .deb: a
  tree of ordinary ELFs, which autoPatchelfHook rewrites in place. This is a
  *Bun single-file executable* -- the JavaScript, its assets and the Bun runtime
  are one 135MB ELF with the payload addressed relative to the file itself.

  So the binary must stay BYTE-IDENTICAL, which is what shapes everything below.
  Measured, not assumed:

  - patchelf --set-interpreter grew the file by 8192 bytes (a rewritten
    program-header table) and every later invocation dumped core, `--version`
    included. Hence dontPatchELF/dontStrip.

  - Invoking glibc's ld.so explicitly (`ld-linux ... --library-path X binary`)
    DOES run it -- but only for one-shot commands. The daemon re-execs itself
    from /proc/self/exe, which under an explicit loader IS the loader, so
    `serve --detached` became `ld.so serve` and died with
    "serve: cannot open shared object file". A wrapper cannot fix that: the
    re-exec happens inside the app.

  That leaves running it through its own PT_INTERP, /lib64/ld-linux-x86-64.so.2,
  which on NixOS means nix-ld -- see ./nixos.nix, which enables it. The whole
  NEEDED set is glibc, so NIX_LD alone is the entire runtime link for this
  binary; the wider library list is for its CHILDREN, which are foreign too: the
  daemon downloads micromamba and a conda stack into ~/.claude-science at
  runtime and runs those (verified: that micromamba is a generic-linux ELF
  needing only glibc, and it runs once a real loader is reachable).

  nix-ld also means no buildFHSEnv, which was the first plan while the app
  looked Electron-shaped. `claude-science serve` runs a daemon and opens the web
  UI in a browser, so nothing here needs the Electron zip the binary fetches at
  runtime for its optional native window -- and an FHS namespace would have sat
  awkwardly under the app's own bubblewrap sandboxing anyway.
*/
stdenvNoCC.mkDerivation {
  pname = "claude-science";
  inherit version src;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # Both would corrupt the payload; see the header.
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/libexec/claude-science"

    makeWrapper "$out/libexec/claude-science" "$out/bin/claude-science" \
      --prefix PATH : ${
        lib.makeBinPath [
          # The daemon sandboxes Claude's tool calls with bubblewrap when the
          # kernel allows unprivileged userns, and falls back to a weaker mode
          # without it -- so this is a security-relevant dependency, not a
          # convenience one.
          bubblewrap
          # `serve` opens the web UI; it shells out to xdg-open unless given
          # --no-browser.
          xdg-utils
          # These two are NOT redundant with the session's own PATH, which is
          # exactly the trap they exist to avoid. The daemon resolves `bash` on
          # PATH and then runs it INSIDE its bubblewrap sandbox, so a
          # session-PATH answer of /run/current-system/sw/bin/bash is a path
          # that does not exist in that namespace:
          #   bwrap: execvp /run/current-system/sw/bin/bash: No such file
          # -- which failed every bundled MCP connector's environment probe.
          # Resolving to a /nix/store path instead gives an answer that is
          # still valid inside the sandbox, which binds the store. Measured:
          # 0 bwrap errors afterwards, against 8 before.
          bash
          coreutils
          # Hard requirement, not a fallback: the daemon refuses to boot
          # without it -- "socat is required for Linux sandbox networking but
          # was not found in PATH. Install it with: sudo apt-get install
          # socat". It scans PATH itself (accessSync X_OK) and runs socat as
          # the HTTP and SOCKS bridges between the sandbox's AF_UNIX sockets
          # in the data dir and localhost, which is how Claude's tool calls
          # reach the network under approval. It is not in the default system
          # profile here, so PATH must carry it.
          socat
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "Run Claude on your data, locally, in your browser";
    homepage = "https://claude.com/product/claude-science";
    # Anthropic ships this as a prebuilt binary under their consumer terms;
    # no licence file accompanies it.
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude-science";
  };
}
