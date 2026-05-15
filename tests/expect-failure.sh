#!/usr/bin/env bash
set -Eeuo pipefail

if "$@"; then
  echo "::error::Command unexpectedly succeeded: $*"
  exit 1
fi

echo "::notice::Command failed as expected: $*"
