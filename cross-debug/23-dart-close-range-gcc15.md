# `dart-3.11.4`: `close_range` conflicting C linkage + address-never-null (GCC 14+)

**Package:** `dart-x86_64-unknown-linux-gnu-3.11.4` (source build via flutter engine)
**File:** `pkgs/development/compilers/dart/source/gcc15-close-range.patch`
**Underlying source:** `runtime/bin/process_linux.cc`

## Symptom 1 — conflicting C language linkage

```
runtime/bin/process_linux.cc:286:16: error: conflicting C language linkage
declaration 'int dart::bin::close_range(unsigned int, unsigned int, int)' [-Werror]
```

GCC 14+ enforces `-Werror=conflicting-C-language-linkage-declaration`.

## Root Cause 1

Dart declared a weak `extern "C"` fallback for `close_range` inside
`namespace dart::bin` to detect kernel support at runtime:

```cpp
// Linux 5.9, glibc 2.34.
extern "C" int close_range(unsigned int first, unsigned int last, int flags)
    __attribute__((weak));
```

But glibc 2.34+ already declares `close_range` in `<unistd.h>` with C linkage.
Having two `extern "C"` declarations with the same mangled name in different
C++ namespaces is a GCC 14+ error.

## Symptom 2 — address of non-weak symbol is never null

```
runtime/bin/process_linux.cc:297:20: error: the address of
'int close_range(...)' will never be NULL [-Werror=address]
```

## Root Cause 2

After guarding the weak declaration with `#if !__GLIBC_PREREQ(2, 34)`, the
code still contained `if (&close_range != nullptr)`. On glibc >= 2.34,
`close_range` is a strong symbol from libc — GCC knows its address is never
null and fires `-Werror=address`.

## Fix

Patch `runtime/bin/process_linux.cc`:

1. Guard the weak declaration with `#if !__GLIBC_PREREQ(2, 34)`
2. Guard the null address check too: on glibc >= 2.34, replace it with `if (true)`

```diff
 // Linux 5.9, glibc 2.34.
+#if !defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 34)
 extern "C" int close_range(unsigned int first, unsigned int last, int flags)
     __attribute__((weak));
+#endif
 
 void CloseAllButStdioAndExecControl(int exec_control_fd) {
 #if defined(DART_HOST_OS_ANDROID)
   if (__builtin_available(android 34, *)) {
 #elif defined(DART_HOST_OS_LINUX)
+#  if !defined(__GLIBC_PREREQ) || !__GLIBC_PREREQ(2, 34)
   if (&close_range != nullptr) {
+#  else
+  if (true) {  // glibc >= 2.34 always provides close_range
+#  endif
 #else
```

File: `pkgs/development/compilers/dart/source/gcc15-close-range.patch`
Added to `patches` list after `gcc13.patch` in `source/default.nix`.
