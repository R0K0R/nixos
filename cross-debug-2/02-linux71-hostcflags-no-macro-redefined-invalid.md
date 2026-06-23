# 02 — Linux 7.1 kernel: invalid `-Wno-macro-redefined` in HOSTCFLAGS

## Symptom

During early investigation of the kernel `__attribute_const__` failure, an attempt
was made to silence the warning via `-Wno-macro-redefined` in `HOSTCFLAGS` in
`common-flags.nix`. This flag was invalid:

```
cc1: error: '-Wno-macro-redefined' is valid for C/ObjC but not for C
cc1: error: unrecognized command-line option '-Wno-macro-redefined'
```

GCC uses `-Wno-builtin-macro-redefined` for this specific case, not
`-Wno-macro-redefined`. Clang uses `-Wno-macro-redefined` — the flag was confused
from Clang documentation.

## Fix

Removed `-Wno-macro-redefined` from `HOSTCFLAGS` in
`pkgs/os-specific/linux/kernel/common-flags.nix`.

The remaining `common-flags.nix` HOSTCFLAGS:

```nix
"HOSTCFLAGS=-Wno-error"
"EXTRA_WARNINGS="
```

- `-Wno-error`: covers tools where our flags appear last (objtool). Suppresses
  all warning-to-error promotions without silencing individual warnings.
- `EXTRA_WARNINGS=`: overrides the `EXTRA_WARNINGS` makefile variable. The libbpf
  build (via `tools/scripts/Makefile.include`) adds `-Wredundant-decls` via
  `EXTRA_WARNINGS` **after** `EXTRA_CFLAGS=$(HOSTCFLAGS)`, re-enabling the warning.
  Passing `EXTRA_WARNINGS=` on the command line takes GNU Make command-line
  precedence over makefile assignments, preventing the flag from being added.

## Why the fundamental fix beats the flag approach

Even with a valid `-Wno-builtin-macro-redefined`, `resolve_btfids` would still fail
because its Makefile hardcodes `-Werror` after `$(HOSTCFLAGS)`. Any warning
suppression would be overridden. The real fix (patch #01) makes the definitions
identical so no warning fires at all.
