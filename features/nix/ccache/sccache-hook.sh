# shellcheck shell=bash
# sccache for cargo builds: the setup hook features/nix/ccache/sccache.nix adds
# to every buildRustPackage in the tuned host set. Why each step is here is in
# that file; this is only the mechanism.
#
# Substituted: @sccache@ (the binary), @wrapper@ (RUSTC_WRAPPER),
# @dir@ (the shared cache dir), @conf@ (the builder's sccache config file).

# Move cargoSetupPostUnpackHook's vendor copy from /build/<pname>-<version>-vendor
# to one path every package shares, and leave a symlink at the old name for
# anything that still says it. Unconditional -- it runs whether or not this
# builder has a cache, so the output never depends on the builder.
sccacheFixVendorPath() {
    local top=${NIX_BUILD_TOP:?}
    # cargoVendorDir: the vendor tree sits inside the source and stays there.
    [ -z "${cargoVendorDir-}" ] && [ -n "${cargoDeps-}" ] || return 0

    local fixed=$top/cargo-vendor
    local old
    old=$top/$(stripHash "$cargoDeps")
    [ "$old" != "$fixed" ] && [ -d "$old" ] && [ ! -L "$old" ] || return 0

    local config=$top/.cargo/config.toml
    if ! [ -f "$config" ] || ! grep -qF "\"$old" "$config"; then
        echo "sccache-hook: $config does not point at $old; vendor path left as is"
        return 0
    fi
    if [ -e "$fixed" ]; then
        echo "sccache-hook: $fixed already exists; vendor path left as is"
        return 0
    fi

    mv -- "$old" "$fixed"
    ln -s cargo-vendor "$old"
    # Literal replacement (bash pattern with quoted operands), and only where
    # the old path is a whole path or a prefix of one: "<old>" or "<old>/...".
    local c from to
    c=$(<"$config")
    from="\"$old\"" to="\"$fixed\""
    c=${c//"$from"/"$to"}
    from="\"$old/" to="\"$fixed/"
    c=${c//"$from"/"$to"}
    printf '%s\n' "$c" >"$config"
    if [ "${cargoDepsCopy-}" = "$old" ]; then
        cargoDepsCopy=$fixed
    fi
    echo "sccache-hook: vendored crates moved to $fixed"
}

# RUSTC_WRAPPER always (it also carries the vendor remap, which must not
# depend on the builder); sccache only when the builder has the cache.
sccacheSetup() {
    if [ -n "${RUSTC_WRAPPER-}" ]; then
        echo "sccache-hook: package sets RUSTC_WRAPPER=$RUSTC_WRAPPER; leaving it alone"
        return 0
    fi
    export RUSTC_WRAPPER=@wrapper@

    # Degrade, don't die: a builder that has not got the cache yet (not
    # switched, yulee before yulee.md is done, a sandbox without the path)
    # builds uncached instead of failing every Rust package.
    if ! [ -r "@conf@" ] || ! [ -d "@dir@" ] || ! [ -w "@dir@" ]; then
        echo "sccache-hook: @dir@ or @conf@ is not usable in this sandbox; building without sccache"
        return 0
    fi

    # The server inherits this umask: 002 so the ten nixbld users can all
    # write into the directories each other's servers create. (Only with
    # sccache-entry-mode.patch: unpatched, daemonizing resets it to 027.)
    # Its output goes to a file, not a pipe: the daemon inherits the
    # descriptors, and a $(...) would wait on it until the build ends.
    # No idle shutdown: the server lives exactly as long as the build (stopped
    # in postInstall, or killed with the sandbox), so a long final link cannot
    # time it out between two compiles.
    export SCCACHE_CONF="@conf@" SCCACHE_IDLE_TIMEOUT=0
    local log=$NIX_BUILD_TOP/.sccache-server.log
    if (umask 002 && exec "@sccache@" --start-server) >"$log" 2>&1; then
        # A server that dies mid-build must cost a cache miss, not the build.
        export SCCACHE_IGNORE_SERVER_IO_ERROR=1
        export NIX_SCCACHE_ACTIVE=1
        echo "sccache-hook: sccache server up (@conf@)"
    else
        unset SCCACHE_CONF SCCACHE_IDLE_TIMEOUT
        echo "sccache-hook: sccache server did not start; building without sccache:"
        cat "$log"
    fi
}

sccacheStop() {
    [ -n "${NIX_SCCACHE_ACTIVE-}" ] || return 0
    # --stop-server prints the build's stats, which is the record of what hit.
    "@sccache@" --stop-server || true
    unset NIX_SCCACHE_ACTIVE
}

sccachePostPatch() {
    sccacheFixVendorPath
    sccacheSetup
}

postPatchHooks+=(sccachePostPatch)
postInstallHooks+=(sccacheStop)
