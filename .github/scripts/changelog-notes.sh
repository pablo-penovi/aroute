#!/usr/bin/env bash
# Prints the CHANGELOG.md section for a version, without its "## [x.y.z]"
# heading, link definitions, or surrounding blank lines. Fails if the
# version has no section.
#
#   changelog-notes.sh VERSION [CHANGELOG]
set -euo pipefail

version=${1:?usage: changelog-notes.sh VERSION [CHANGELOG]}
file=${2:-CHANGELOG.md}

awk -v heading="## [$version]" '
    /^## \[/ {
        if (found) exit
        if (index($0, heading) == 1) found = 1
        next
    }
    found && !/^\[[^]]+\]: / { lines[++n] = $0 }
    END {
        if (!found) {
            print "changelog-notes: no \"" heading "\" section in CHANGELOG" > "/dev/stderr"
            exit 1
        }
        first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
        last = n;  while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = first; i <= last; i++) print lines[i]
    }
' "$file"
