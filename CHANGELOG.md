# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2026-10-31

### Added

- `aroute --list` prints the PipeWire audio Endpoints (one per node, direction and port-name stem), the Connections between them, and the snapshot of `FROM|TO` port names, in the script's format. Unlike the script, every snapshot line is indented and it exits 0 when there are no Connections. MIDI, split devices and hidden Endpoints are not listed yet.
- Display names are rewritten by the `aliases` file, as in the script.
- Design for the Zig rewrite of the `aroute` bash script: on-screen letter picking with paging, per-column search, and parity with the script's CLI and profile format.
- Glossary of domain terms and first architecture decision record.
- Zig build skeleton with `test` and `coverage` (kcov) steps.
- CI (tests, Linux cross-builds, format check) and coverage report on GitHub Pages.
- Release flow: merging a PR tags the merge commit as the next release candidate of the `build.zig.zon` version (`vx.y.z-rcN`); the manually run "Promote tag to release" workflow publishes the latest release candidate of a version newer than the latest release as release `vx.y.z`, with `x86_64-linux` and `aarch64-linux` binaries and notes from this changelog.
