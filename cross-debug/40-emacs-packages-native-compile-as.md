# 40: emacs packages native-compile: plain `as` missing (generic.nix)

## Error
```
x86_64-unknown-linux-gnu-gcc-15.2.0: fatal error: cannot execute 'as': posix_spawnp: No such file or directory
compilation terminated.
```
Seen in: `emacs-vterm-x86_64-unknown-linux-gnu` (and would affect all emacs packages with native compilation).

## Root cause
Same as fix #39 (emacs itself): the cross binutils-wrapper only puts
`x86_64-unknown-linux-gnu-as` (prefixed) in PATH. When emacs runs
`batch-native-compile`, libgccjit invokes `x86_64-unknown-linux-gnu-gcc`, which
looks for plain `as` to assemble — not found.

Fix #39 patched `make-emacs.nix` (emacs itself's configure phase). But the AOT
compilation of emacs *packages* happens in a separate builder (`generic.nix`)
and has the same problem.

## Fix
`pkgs/applications/editors/emacs/build-support/generic.nix`

Add to the `postInstall` block (inside the `emacs.withNativeCompilation` guard),
before the `find | xargs emacs batch-native-compile` call:

```nix
${lib.optionalString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
  export PATH="${stdenv.cc.bintools.bintools}/${stdenv.hostPlatform.config}/bin:$PATH"
''}
```

The `bintools.bintools` package has `x86_64-unknown-linux-gnu/bin/as` (plain
name) which is what GCC's internal driver expects. The exported PATH is inherited
by the `sh -c "emacs ..."` subprocesses spawned by xargs.

## Scope
Affects all emacs packages that enable native compilation in a pseudo-cross build.
