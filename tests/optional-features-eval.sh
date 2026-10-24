#!/usr/bin/env bash
# Evaluate evalTests.optional-features with builds disabled: an IFD that is not
# already in the store fails the evaluation instead of building it.
# usage: tests/optional-features-eval.sh [flake-dir]
set -euo pipefail
dir=${1:-$(dirname "$0")/..}
nix eval --json --option builders '' --option max-jobs 0 \
  --option substituters 'https://cache.nixos.org' \
  "$dir#evalTests.optional-features" | jq .
