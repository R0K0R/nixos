# 04 — HTML-Tree: Module::Build rmtree crash (Perl 5.42 + pseudo-cross fastcwd)

## Symptom

```
Unsuccessful stat on filename containing newline at
  /nix/store/.../perl-5.42.0/lib/perl5/5.42.0/File/Path.pm line 361.
cannot stat initial working directory for /build/HTML-Tree-5.07
: No such file or directory at
  /nix/store/.../Module-Build-0.4234/.../Module/Build/Base.pm line 5293.
Couldn't remove 'blib/script/htmltree.bak': No such file or directory
```

## Root cause (layered)

### Layer 1: Module::Build uses deprecated `File::Path::rmtree`

`Module::Build::Base::delete_filetree()` calls `File::Path::rmtree()`, the legacy
(two-argument) API that was deprecated in Perl 5.12. This API:
1. Saves the current working directory via `Cwd::fastcwd()`
2. Recursively removes the target tree
3. Restores the cwd via `chdir` to the saved path

### Layer 2: `Cwd::fastcwd()` returns path with trailing newline in pseudo-cross

In the pseudo-cross build environment, `Cwd::fastcwd()` returns a path with a
trailing newline (e.g., `/build/HTML-Tree-5.07\n`). This is likely caused by an
interaction between the cross cc-wrapper's PATH manipulation and how `fastcwd()`
uses a shell command internally.

### Layer 3: Perl 5.42 `stat` strict newline handling

Perl 5.42 added a warning/error for `stat` called with a filename containing a
newline: "Unsuccessful stat on filename containing newline". This turns the fastcwd
cwd-restoration step from a silent failure (older Perl) into a hard crash.

The cascade: `delete_filetree` → `rmtree` → `fastcwd()` returns `path\n` → `chdir(path\n)` →
`stat(path\n)` → Perl 5.42 warns → caller throws exception → shell loses cwd →
"cannot stat initial working directory".

## Failed fix: removing Build.PL in postPatch

First attempt:
```nix
HTMLTree = psuper.HTMLTree.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    rm -f Build.PL
  '';
});
```

This didn't work because `buildPerlModule` (which `HTMLTree` uses) hardcodes
`perl Build.PL` directly in `buildPhase`:

```nix
buildPerlModule = args: buildPerlPackage ({
  buildPhase = ''
    runHook preBuild
    perl Build.PL --prefix=$out;
    perl ./Build build
    runHook postBuild
  '';
  ...
} // args // {
  preConfigure = ''
    touch Makefile.PL
    ${args.preConfigure or ""}
  '';
  buildInputs = (args.buildInputs or []) ++ [ ModuleBuild ];
});
```

Even after `rm -f Build.PL`, `perl Build.PL` still ran in `buildPhase`.
The build was also using Module::Build because the override wasn't reaching the
right perlPackages scope (perlPackages uses `lib.makeScope` and requires
`overrideScope`, not `//`).

## Fix

`buildPerlModule`'s `builder.sh` preConfigure always runs `perl Makefile.PL` first
(before the custom `buildPhase` runs `perl Build.PL`). HTML-Tree ships both
`Build.PL` and `Makefile.PL`. The MakeMaker build path avoids Module::Build and
its `rmtree` call entirely.

Override the build phases to use `make` instead of `./Build`:

```nix
perlPackages = prev.perlPackages.overrideScope (pself: psuper: {
  HTMLTree = psuper.HTMLTree.overrideAttrs (old: {
    buildPhase = ''
      runHook preBuild
      make
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      make install
      runHook postInstall
    '';
    checkPhase = ''
      runHook preCheck
      make test
      runHook postCheck
    '';
  });
});
```

**Why `overrideScope` and not `//`:** `perlPackages` is a fixed-point scope created
with `lib.makeScope`. Using `prev.perlPackages // { HTMLTree = ...; }` bypasses the
fixed point and the new HTMLTree is not seen by other packages in the scope
(e.g., HTML::Formatter) that depend on it. `overrideScope` threads the override
through the entire scope's dependency graph.

## Cross-debug category

**Perl 5.42 strict + pseudo-cross environment interaction.** The underlying
`fastcwd()` newline issue may be triggered by the cross cc-wrapper's PATH
manipulation. Perl 5.42's stricter `stat` turns it fatal. Two fixes are available
upstream: (1) fix `fastcwd()` to strip trailing newlines, (2) port Module::Build
to use the modern `File::Path::remove_tree` API which doesn't use `fastcwd()`.
Both are upstream Perl/CPAN fixes.
