/*
  features/nix/ccache, crossDerivation: a BUILD test (not eval-only) of the
  patched ccache's dependency-file rewrite. Plain upstream nixpkgs, the same
  ccache tuning/overlays/heavy.nix patches; runs anywhere a sandbox builds
  (`nix build .#checks.x86_64-linux.ccache-depfile`).

  The bug it pins: with CCACHE_NIX_STORE_NORMALIZE a hit crosses store hashes,
  and ccache used to restore the cached .d verbatim -- naming the OTHER
  derivation's store paths, which waf's gccdeps rejects (samba's configure,
  2026-10-15). The builder's real config is reproduced in a fresh CCACHE_DIR
  inside the build, so no real cache is touched: direct_mode = false, the same
  ignore_options, normalization on.

  Cases, each "prime with A, then the same compile with B":
    1   header byte-identical, only the store hash differs -> HIT, and the .d
        (also with -MP) and the replayed warning name B, not A
    2   header content differs -> miss
    3   the .d names a store path with no line marker in this compilation (a
        file #embed'ed next to the header) -> miss, rather than guess
    4   -fstack-usage: the .su names the header -> no normalization, miss
    info  __builtin_FILE() in a header: NOT handled, printed only. The object
        keeps A's (nixpkgs-gcc-mangled, so not a reference) path.

  `ccache` / `expectFixed` exist to run the same body against an unfixed
  ccache and show the bug (expectFixed = false prints instead of failing).
*/
{
  inputs,
  lib,
  pkgs ? inputs.nixpkgs-upstream.legacyPackages.x86_64-linux,
  ccache ? pkgs.ccache.overrideAttrs (o: {
    patches = (o.patches or [ ]) ++ [ ../features/nix/ccache/nix-store-normalize.patch ];
  }),
  expectFixed ? true,
  name ? "ccache-depfile",
}:
let
  inherit (pkgs) runCommand writeText;
  header = writeText "dep.h" ''
    #ifndef DEP_H
    #define DEP_H
    static int dep_unused_in_header;
    static inline int dep_inline(int x) { return x * 3; }
    static inline const char *dep_where(void) { return __builtin_FILE(); }
    #endif
  '';
  # Same name, byte-identical header, different store path: they differ only
  # in an environment variable, so only the store hash differs.
  mkHdr = variant: extra: runCommand "dep-hdr" { inherit variant; } ''
    mkdir -p $out/include
    cat ${header} > $out/include/dep.h
    ${extra}
  '';
  hdrA = mkHdr "a" "";
  hdrB = mkHdr "b" "";
  # Same name, different content.
  hdrC = mkHdr "c" "echo 'int dep_extra;' >> $out/include/dep.h";
  # A header that #embeds a file next to it: the dependency file names the
  # embedded file, the line markers do not.
  mkEmbedHdr = variant: runCommand "dep-embed" { inherit variant; } ''
    mkdir -p $out/include
    printf 'ABCD' > $out/include/blob.bin
    printf '%s\n' 'static const char dep_data[] = {' '#embed "blob.bin"' '};' > $out/include/dep2.h
  '';
  embA = mkEmbedHdr "a";
  embB = mkEmbedHdr "b";
in
pkgs.runCommandCC name { nativeBuildInputs = [ ccache pkgs.binutils ]; } ''
  set -u
  export CCACHE_DIR=$TMPDIR/cc
  mkdir -p $CCACHE_DIR
  cat > $CCACHE_DIR/ccache.conf <<CONF
  direct_mode = false
  ignore_options = -I* -isystem* -idirafter* -iquote*
  CONF
  export CCACHE_NIX_STORE_NORMALIZE=1 CCACHE_SLOPPINESS=random_seed CCACHE_UMASK=002
  export CCACHE_LOGFILE=$TMPDIR/ccache.log
  ccache --version | sed -n 1p
  cc=$(command -v gcc)

  cat > main.c <<'C'
  #include <dep.h>
  int main(void) { return dep_inline(1); }
  C
  cat > where.c <<'C'
  #include <dep.h>
  const char *w(void) { return dep_where(); }
  C
  cat > embed.c <<'C'
  #include <dep.h>
  #include <dep2.h>
  int e(void) { return dep_data[0] + dep_inline(2); }
  C

  fails=0
  check() { # check <description> <command...>
    if "''${@:2}"; then echo "  ok:   $1"; else echo "  FAIL: $1"; fails=$((fails+1)); fi
  }
  hits() { ccache --print-stats | awk '$1=="preprocessed_cache_hit"{print $2}'; }
  misses() { ccache --print-stats | awk '$1=="preprocessed_cache_miss"{print $2}'; }
  # comp <label> <src> <args...>: one compile, reporting hit or miss.
  comp() {
    local label=$1 src=$2; shift 2
    local h0=$(hits) m0=$(misses)
    ccache $cc -Wall -fdiagnostics-color=never -c "$src" -o out.o -MD -MF out.d "$@" 2> stderr.txt
    local h1=$(hits) m1=$(misses)
    if [ "$h1" -gt "$h0" ]; then result=hit; elif [ "$m1" -gt "$m0" ]; then result=miss; else result=other; fi
    echo "== $label: $result (preprocessed_cache_hit $h0 -> $h1, preprocessed_cache_miss $m0 -> $m1)"
    sed 's/^/   .d | /' out.d
    sed 's/^/  err | /' stderr.txt
  }
  names() { grep -q -- "$1" "$2"; }
  lacks() { ! grep -q -- "$1" "$2"; }

  echo "A=${hdrA}"; echo "B=${hdrB}"; echo "C=${hdrC}"

  echo; echo "### 1. same header at a store-hash-only different path: hit, .d rewritten"
  comp "prime with A" main.c -I${hdrA}/include
  check "prime is a miss" test "$result" = miss
  comp "same TU with B" main.c -I${hdrB}/include
  check "B is a hit" test "$result" = hit
  check ".d names B" names "${hdrB}/include/dep.h" out.d
  check ".d does not name A" lacks "${hdrA}" out.d
  check "stderr names B" names "${hdrB}/include/dep.h" stderr.txt
  check "stderr does not name A" lacks "${hdrA}" stderr.txt

  echo; echo "### 1b. same with -MP (phony header targets)"
  comp "prime with A, -MP" main.c -I${hdrA}/include -MP
  comp "B, -MP" main.c -I${hdrB}/include -MP
  check "B -MP is a hit" test "$result" = hit
  check ".d (-MP) does not name A" lacks "${hdrA}" out.d

  echo; echo "### 2. header content differs: miss"
  comp "same TU with C" main.c -I${hdrC}/include
  check "C is a miss" test "$result" = miss

  echo; echo "### 3. .d names a store path this compilation has no line marker for (#embed): miss"
  comp "prime embed with A" embed.c -std=c23 -I${hdrA}/include -I${embA}/include
  comp "embed with B" embed.c -std=c23 -I${hdrB}/include -I${embB}/include
  check "embed with B is a miss" test "$result" = miss
  check ".d (embed) names blob B" names "${embB}/include/blob.bin" out.d
  check ".d (embed) does not name A" lacks "${embA}" out.d

  echo; echo "### 4. -fstack-usage: the .su names the header, so no normalization: miss"
  comp "prime -fstack-usage with A" main.c -O0 -fstack-usage -I${hdrA}/include
  comp "-fstack-usage with B" main.c -O0 -fstack-usage -I${hdrB}/include
  sed 's/^/   .su | /' out.su
  check "-fstack-usage with B is a miss" test "$result" = miss
  check ".su does not name A" lacks "${hdrA}" out.su

  echo; echo "### info: __builtin_FILE() in a header (NOT handled; reported, not asserted)"
  comp "prime where.c with A" where.c -O2 -I${hdrA}/include
  comp "where.c with B" where.c -O2 -I${hdrB}/include
  echo "   object strings naming dep-hdr:"; strings out.o | grep dep-hdr | sed 's/^/   .o | /' || true

  echo; echo "### ccache log lines from the patch"
  grep -E "Not using result|Rewrote store paths" $CCACHE_LOGFILE | sed 's/^\[[^]]*\] *//; s/^/  log | /' || true

  echo; ccache --print-stats | grep -E '^(preprocessed_cache_hit|preprocessed_cache_miss|direct_cache_hit)[[:space:]]' || true
  echo; echo "failures: $fails"
  ${if expectFixed then ''[ "$fails" -eq 0 ] || exit 1'' else ""}
  touch $out
''
