#!/usr/bin/env bash
# Evaluate evalTests.gl-namespace with builds disabled: an IFD that is not
# already in the store fails the evaluation instead of building it.
# usage: tests/gl-namespace-eval.sh [flake-dir]
set -euo pipefail
dir=${1:-$(dirname "$0")/..}
nix eval --json --option builders '' --option max-jobs 0 \
  --option substituters 'https://cache.nixos.org' \
  "$dir#evalTests.gl-namespace" | jq .
