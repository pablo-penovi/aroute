#!/usr/bin/env bash
# Prints the release notes for VERSION from CHANGELOG.md: every section
# after PREVIOUS up to and including VERSION, newest first, so a release
# covers all the versions since the last one. Link definitions and blank
# lines around the notes are left out. With a single section, its
# "## [x.y.z]" heading is left out too (the release title says it); with
# several, each keeps its heading. Without --since, every section up to
# VERSION. Fails if VERSION has no section.
#
#   changelog-notes.sh [--since PREVIOUS] VERSION [CHANGELOG]
set -euo pipefail

usage="usage: changelog-notes.sh [--since PREVIOUS] VERSION [CHANGELOG]"
since=""
if [ "${1:-}" = "--since" ]; then
    since=${2:?$usage}
    shift 2
fi
version=${1:?$usage}
file=${2:-CHANGELOG.md}

awk -v version="$version" -v since="$since" '
    # Compares two x.y.z versions: <0, 0 or >0.
    function cmp(a, b,    x, y, i) {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) return x[i] - y[i]
        return 0
    }
    /^## \[/ {
        v = substr($0, 5); sub(/\].*/, "", v)
        keep = v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && cmp(v, version) <= 0 && (since == "" || cmp(v, since) > 0)
        if (keep) {
            if (v == version) found = 1
            sections++
            lines[++n] = $0
            heading[n] = 1
        }
        next
    }
    keep && !/^\[[^]]+\]: / { lines[++n] = $0 }
    END {
        if (since != "" && cmp(since, version) >= 0) {
            print "changelog-notes: " version " is not newer than " since > "/dev/stderr"
            exit 1
        }
        if (!found) {
            print "changelog-notes: no \"## [" version "]\" section in CHANGELOG" > "/dev/stderr"
            exit 1
        }
        # Blank lines only between text: one after each heading, none at
        # either end of a section.
        for (i = 1; i <= n; i++) {
            if (heading[i]) {
                if (sections == 1) continue
                if (out) print ""
                print lines[i]
                out = 1; fresh = 1; blanks = 0
            } else if (lines[i] ~ /^[[:space:]]*$/) {
                if (out && !fresh) blanks++
            } else {
                if (fresh) print ""
                for (; blanks > 0; blanks--) print ""
                print lines[i]
                out = 1; fresh = 0; blanks = 0
            }
        }
    }
' "$file"
