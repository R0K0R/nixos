#!/usr/bin/env bash
# Evaluate evalTests.user-types with builds disabled: an IFD that is not
# already in the store fails the evaluation instead of building it.
# usage: tests/user-types-eval.sh [--scripts] [flake-dir]
#   --scripts  also print the generated type-record shell and the .drv paths
#              of the handover/kiosk scripts (hidden by default;
#              it is long, and every check on it is already in the output)
set -euo pipefail
filter='del(.scripts)'
if [ "${1:-}" = --scripts ]; then
  filter=.
  shift
fi
dir=${1:-$(dirname "$0")/..}
nix eval --json --option builders '' --option max-jobs 0 \
  --option substituters 'https://cache.nixos.org' \
  "$dir#evalTests.user-types" | jq "$filter"
