#!/usr/bin/env bash
# Evaluate evalTests.class-daemons with builds disabled: an IFD that is not
# already in the store fails the evaluation instead of building it.
# usage: tests/class-daemons-eval.sh [--files] [flake-dir]
#   --files  also print the generated nix.conf / machines / ssh_config /
#            routing snippet (hidden by default; every check on them is
#            already in the output)
set -euo pipefail
filter='del(.files)'
if [ "${1:-}" = --files ]; then
  filter=.
  shift
fi
dir=${1:-$(dirname "$0")/..}
nix eval --json --option builders '' --option max-jobs 0 \
  --option substituters 'https://cache.nixos.org' \
  "$dir#evalTests.class-daemons" | jq "$filter"
