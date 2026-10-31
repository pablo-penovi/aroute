# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Design for the Zig rewrite of the `aroute` bash script: on-screen letter picking with paging, per-column search, and parity with the script's CLI and profile format.
- Glossary of domain terms and first architecture decision record.
- Zig build skeleton with `test` and `coverage` (kcov) steps.
- CI (tests, Linux cross-builds, format check) and coverage report on GitHub Pages.
- Release flow: merging a PR with a plain `x.y.z` version in `build.zig.zon` drafts release `vx.y.z`; publishing it as the latest release attaches `x86_64-linux` and `aarch64-linux` binaries and sets its notes from this changelog.
