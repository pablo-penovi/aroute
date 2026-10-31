#!/usr/bin/env bash
# Prints the highest N among the local vVERSION-rcN tags, or 0 if there are
# none. Needs the tags fetched (actions/checkout with fetch-depth: 0).
#
#   latest-rc.sh VERSION
set -euo pipefail

version=${1:?usage: latest-rc.sh VERSION}

git tag -l "v$version-rc*" | awk -v prefix="v$version-rc" '
    index($0, prefix) == 1 {
        n = substr($0, length(prefix) + 1)
        if (n ~ /^[0-9]+$/ && n + 0 > max) max = n + 0
    }
    END { print max + 0 }
'
