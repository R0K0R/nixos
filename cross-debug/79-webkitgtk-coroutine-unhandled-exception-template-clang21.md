# cross-debug/79: webkitgtk — unhandled_exception() template breaks C++20 coroutines under clang 21

## Problem

`webkitgtk-2.52.3+abi=4.1-x86_64-unknown-linux-gnu` fails to compile multiple
WebKit UIProcess files:

```
Source/WebKit/UIProcess/WebPageProxy.cpp:15095:31: error: no matching member function for call to 'unhandled_exception'
15095 | Awaitable<void> WebPageProxy::nextPresentationUpdate()
      |                               ^~~~~~~~~~~~~~~~~~~~~~
Source/WTF/wtf/CoroutineUtilities.h:77:14: note: candidate template ignored: couldn't infer template argument 'Promise'
   77 |         void unhandled_exception() { }
```

Same error appears in WebFullScreenManagerProxy.cpp and other files using
`Awaitable<T>` coroutines.

## Root cause

`Source/WTF/wtf/CoroutineUtilities.h` defines `unhandled_exception` as a **function
template** inside the `PromiseBase` class:

```cpp
class PromiseBase {
    ...
    template<typename Promise>
    std::coroutine_handle<> await_suspend(std::coroutine_handle<Promise> coroutine) noexcept
        { return coroutine.promise().handle(); }
    template<typename Promise>           // <-- THIS IS THE BUG
    void unhandled_exception() { }
    ...
};
```

The C++20 coroutine machinery calls `promise.unhandled_exception()` with no template
arguments and no arguments at all.  The `template<typename Promise>` prefix makes
`unhandled_exception` a function template; since it takes no arguments, `Promise`
can never be inferred, so the call fails.

The `await_suspend` above it correctly uses `template<typename Promise>` because it
takes `std::coroutine_handle<Promise>` as an argument, allowing deduction.

**Older clang (≤ 20)** apparently tolerated this (possibly through a coroutine
lookup extension that accepted the template candidate after substitution with the
promise type).  **Clang 21** is strict: the candidate is rejected because template
argument deduction fails, and there are no other candidates.

## Fix

Strip the erroneous `template<typename Promise>` line preceding `unhandled_exception`
in a postPatch, using perl for reliable multiline substitution (perl is already a
nativeBuildInput of webkitgtk):

```bash
perl -i -0pe 's/template<typename Promise>\n(\s*void unhandled_exception)/$1/g' \
  Source/WTF/wtf/CoroutineUtilities.h
```

The `await_suspend` template immediately above is untouched — its `template<typename
Promise>` line has `await_suspend` on the next line, not `unhandled_exception`, so
the pattern doesn't match it.

Fix is in `nixpkgs-patch` (global) because this is a clang-21 compatibility issue
that affects all webkitgtk builds, not just the pseudo-cross meteorlake build.

## Files

- `pkgs/development/libraries/webkitgtk/default.nix` — perl substituteInPlace in postPatch
