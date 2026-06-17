# cross_perl Cwd.pm: `chomp` No-Op When `$/` Is `undef`

**Package:** `perl5.42.0-HTML-Tree` (and any package using Module::Build)
**File:** `pkgs/development/interpreters/perl/interpreter.nix`, new `cross-Cwd.pm`

## Symptom

```
Unsuccessful stat on filename containing newline at .../Module/Build/Base.pm
```

Build fails when Module::Build tries to stat a file path that ends with `\n`.

## Root Cause

The cross mini-perl stub `cnf/stub/Cwd.pm` does:

```perl
sub cwd {
    my $cwd = `pwd`;
    chomp $cwd;
    return $cwd;
}
```

`Module::Build::Base::fix_shebang_line` (line ~3107) sets `undef $/` (the record
separator) to slurp files. This `undef $/` is NOT in a nested scope — it stays
`undef` when `delete_filetree` is called at line 3118, which calls `cwd()`.

`chomp` removes the trailing `$/` from the string. When `$/` is `undef`, `chomp`
is a no-op. The backtick `pwd` output retains its trailing newline, so the returned
path contains `\n`, causing `stat` to fail.

## Fix

Created `pkgs/development/interpreters/perl/cross-Cwd.pm` using a regex instead:

```perl
sub cwd {
    my $cwd = `pwd`;
    $cwd =~ s/\n+\z// if defined $cwd;
    return $cwd;
}
```

`s/\n+\z//` strips trailing newlines regardless of `$/`.

Injected in `interpreter.nix` `postInstall` (cross-only):

```nix
cp ${./cross-Cwd.pm} "$mini/lib/perl5/cross_perl/${version}/Cwd.pm"
```
