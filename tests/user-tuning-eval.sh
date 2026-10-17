#!/usr/bin/env bash
# Evaluate evalTests.user-tuning with builds disabled: an IFD that is not
# already in the store fails the evaluation instead of building it.
# usage: tests/user-tuning-eval.sh [flake-dir]
set -euo pipefail
dir=${1:-$(dirname "$0")/..}
nix eval --json --option builders '' --option max-jobs 0 \
  --option substituters 'https://cache.nixos.org' \
  "$dir#evalTests.user-tuning" | jq .
