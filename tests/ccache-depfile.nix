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
    5   __builtin_FILE() in a header inline function (C) and
    6   std::source_location::current() in one (C++): the compiler resolves
        them from the line markers, so the key cannot see the path; the cached
        object would name A (as nixpkgs' gcc mangles it: hash uppercased) ->
        the scan of the restored object makes it a miss
    7   a TU that uses <source_location> but puts no header path into the
        object -> still a hit, byte-identical to a CCACHE_DISABLE=1 compile
    timing  ten hits on a multi-MB object, with the patch's own scan timing
        from the log (info only)

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
  headerCxx = writeText "dep.hpp" ''
    #include <source_location>
    inline const char *dep_here() { return std::source_location::current().file_name(); }
  '';
  headerPlain = writeText "plain.hpp" ''
    inline int dep_twice(int x) { return 2 * x; }
  '';
  # Same name, byte-identical header, different store path: they differ only
  # in an environment variable, so only the store hash differs.
  mkHdr = variant: extra: runCommand "dep-hdr" { inherit variant; } ''
    mkdir -p $out/include
    cat ${header} > $out/include/dep.h
    cat ${headerCxx} > $out/include/dep.hpp
    cat ${headerPlain} > $out/include/plain.hpp
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
  # As the builders run it; the scan must see decompressed bytes.
  export CCACHE_COMPRESS=1
  export CCACHE_LOGFILE=$TMPDIR/ccache.log
  ccache --version | sed -n 1p
  cc=$(command -v gcc)
  cxx=$(command -v g++)

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

  cat > here.cpp <<'C'
  #include <dep.hpp>
  const char *h() { return dep_here(); }
  C
  cat > still.cpp <<'C'
  #include <source_location>
  #include <plain.hpp>
  const char *f() { return std::source_location::current().file_name(); }
  int g(int x) { return dep_twice(x); }
  C

  fails=0
  check() { # check <description> <command...>
    if "''${@:2}"; then echo "  ok:   $1"; else echo "  FAIL: $1"; fails=$((fails+1)); fi
  }
  hits() { ccache --print-stats | awk '$1=="preprocessed_cache_hit"{print $2}'; }
  misses() { ccache --print-stats | awk '$1=="preprocessed_cache_miss"{print $2}'; }
  # comp <label> <src> <args...>: one compile, reporting hit or miss.
  comp() { compx "$1" "$cc" "''${@:2}"; }
  compx() {
    local label=$1 compiler=$2 src=$3; shift 3
    local h0=$(hits) m0=$(misses)
    ccache $compiler -Wall -fdiagnostics-color=never -c "$src" -o out.o -MD -MF out.d "$@" 2> stderr.txt
    local h1=$(hits) m1=$(misses)
    if [ "$h1" -gt "$h0" ]; then result=hit; elif [ "$m1" -gt "$m0" ]; then result=miss; else result=other; fi
    echo "== $label: $result (preprocessed_cache_hit $h0 -> $h1, preprocessed_cache_miss $m0 -> $m1)"
    sed 's/^/   .d | /' out.d
    sed 's/^/  err | /' stderr.txt
  }
  # The form nixpkgs' gcc gives __FILE__ / __builtin_FILE(): hash uppercased.
  mangled() { local p=$1 h=''${1:11:32}; echo "/nix/store/''${h^^}''${p:43}"; }
  objnames() { strings -a "$2" | grep -qF -- "$1"; }
  objlacks() { ! strings -a "$2" | grep -qF -- "$1"; }
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

  echo; echo "### 5. __builtin_FILE() in a header inline function (C): the object would name A -> miss"
  comp "prime where.c with A" where.c -O2 -I${hdrA}/include
  comp "where.c with B" where.c -O2 -I${hdrB}/include
  strings -a out.o | grep dep-hdr | sed 's/^/   .o | /' || true
  check "where.c with B is a miss" test "$result" = miss
  check "object names B (mangled)" objnames "$(mangled ${hdrB})" out.o
  check "object does not name A (mangled)" objlacks "$(mangled ${hdrA})" out.o
  check "object does not name A (plain)" objlacks "${hdrA}" out.o

  echo; echo "### 6. std::source_location::current() in a header inline function (C++): miss"
  compx "prime here.cpp with A" "$cxx" here.cpp -std=c++20 -O2 -I${hdrA}/include
  compx "here.cpp with B" "$cxx" here.cpp -std=c++20 -O2 -I${hdrB}/include
  strings -a out.o | grep dep-hdr | sed 's/^/   .o | /' || true
  check "here.cpp with B is a miss" test "$result" = miss
  check "object names B (plain or mangled)" sh -c "strings -a out.o | grep -qiF -- ${hdrB}"
  check "object does not name A (plain or mangled)" sh -c "! strings -a out.o | grep -qiF -- ${hdrA}"

  echo; echo "### 7. <source_location> used, but no header path lands in the object: still a hit, bit-identical"
  compx "prime still.cpp with A" "$cxx" still.cpp -std=c++20 -O2 -I${hdrA}/include
  compx "still.cpp with B" "$cxx" still.cpp -std=c++20 -O2 -I${hdrB}/include
  check "still.cpp with B is a hit" test "$result" = hit
  cp out.o still-cached.o
  CCACHE_DISABLE=1 ccache $cxx -Wall -fdiagnostics-color=never -c still.cpp -o still-fresh.o -MD -MF fresh.d -std=c++20 -O2 -I${hdrB}/include 2>/dev/null
  check "cached object == fresh compile (CCACHE_DISABLE=1)" cmp still-cached.o still-fresh.o

  echo; echo "### timing (info): hits on a large object"
  head -c 16777216 /dev/urandom > big.bin
  { echo '#include <dep.h>'
    echo 'const char big_data[] = {'; echo '#embed "big.bin"'; echo '};'
    for i in $(seq 1 3000); do echo "int f$i(int x) { return x * $i + dep_inline(x); }"; done
  } > big.c
  comp "prime big.c with A" big.c -std=c23 -O0 -I${hdrA}/include > /dev/null
  ls -l out.o | awk '{print "   object bytes: " $5}'
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s0=$(date +%s%N)
    ccache $cc -c big.c -o out.o -std=c23 -O0 -Wall -fdiagnostics-color=never -MD -MF out.d -I${hdrB}/include 2>/dev/null
    s1=$(date +%s%N)
    echo "   hit $i: $(( (s1 - s0) / 1000000 )) ms"
  done
  echo "   hits so far: $(hits)"
  grep "Scanned [0-9]* bytes" $CCACHE_LOGFILE | tail -10 | sed 's/^\[[^]]*\] *//; s/^/  log | /' || true

  echo; echo "### ccache log lines from the patch"
  grep -E "Not using result|Rewrote store paths" $CCACHE_LOGFILE | sed 's/^\[[^]]*\] *//; s/^/  log | /' || true

  echo; ccache --print-stats | grep -E '^(preprocessed_cache_hit|preprocessed_cache_miss|direct_cache_hit)[[:space:]]' || true
  echo; echo "failures: $fails"
  ${if expectFixed then ''[ "$fails" -eq 0 ] || exit 1'' else ""}
  touch $out
''
