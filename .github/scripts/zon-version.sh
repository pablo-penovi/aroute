#!/usr/bin/env bash
# Prints the package version from build.zig.zon.
set -euo pipefail
version=$(sed -n 's/^ *\.version = "\([^"]*\)",.*$/\1/p' "${1:-build.zig.zon}")
[ -n "$version" ] || { echo "zon-version: no .version in ${1:-build.zig.zon}" >&2; exit 1; }
printf '%s\n' "$version"
