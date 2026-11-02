# aroute

[![CI](https://github.com/pablo-penovi/aroute/actions/workflows/ci.yml/badge.svg)](https://github.com/pablo-penovi/aroute/actions/workflows/ci.yml)
[![coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fpablo-penovi.github.io%2Faroute%2Fcoverage-badge.json%3Fv%3D1&cacheSeconds=300)](https://pablo-penovi.github.io/aroute/coverage/)

A two-column patchbay TUI for PipeWire audio and ALSA/PipeWire MIDI, written in Zig.

Sources go on the left (FROM), Destinations on the right (TO). Connect, disconnect, and save the whole set of connections as a profile you can load later. Audio is routed with `pw-link`; MIDI between two ALSA sequencer ports uses `aconnect`, and MIDI involving a PipeWire-only port (e.g. BLE MIDI) goes through PipeWire's Midi-Bridge.

> **Status:** in progress. `--list`, `--profiles`, `--save` and `--load` work as in the script. The TUI shows the home screen, re-read every second, and can connect; disconnecting and the Profile screens are not done yet. This is a rewrite of a bash script of the same name; see [docs/design.md](docs/design.md) for what is planned.

## Usage

```
aroute                  interactive TUI
aroute --list           print devices, connections and the current snapshot
aroute --profiles       list saved profiles
aroute --save NAME      save all current connections as a profile
aroute --load NAME [--force]
                        replace all current connections with a profile
```

In the TUI, items are picked with a letter. When a list doesn't fit, `PgUp`/`PgDn` page through it and `/` searches it.

## Files

- `${XDG_CONFIG_HOME:-~/.config}/aroute/profiles/<name>.conf`: one `FROM|TO` port pair per line. Ports are named `pw:<node.name>:<port.name>` or `alsa:<client name>:<port name>`, never by numeric ID.
- `${XDG_CONFIG_HOME:-~/.config}/aroute/aliases`: display-name overrides, one `text=replacement` per line.

Set `AROUTE_SHOW_ALL=1` to also list normally hidden ports (Midi Through, Sync ports).

## Requirements

- Zig 0.17 to build
- PipeWire with `pw-dump` and `pw-link`
- `aconnect` (alsa-utils)
- `kcov` for coverage reports (development only)

## Building

```sh
zig build -Doptimize=safe -p ~/.local
```

## Development

```sh
# Run the tests
zig build test --summary all

# Run the tests through kcov and merge the coverage reports
zig build coverage
```

Coverage output is written to `coverage/`; open `coverage/merged/kcov-merged/index.html` for the merged report. On every push to `main`, the `Coverage Pages` workflow publishes that report to [GitHub Pages](https://pablo-penovi.github.io/aroute/coverage/) along with the README badge.

## Releasing

`build.zig.zon` always holds a plain `x.y.z` version; release candidates exist only as tags.

1. In a PR, set the version in `build.zig.zon` (`.version = "x.y.z"`) and put the changes in `CHANGELOG.md` under a `## [x.y.z] - YYYY-MM-DD` heading.
2. Merge the PR. The merge commit is tagged as the next release candidate of that version: `vx.y.z-rc1`, then `vx.y.z-rc2` on the next merge at the same version, and so on. No release is created. Once `vx.y.z` is released, merges at that version are no longer tagged; bump the version.
3. To release, run the **Promote tag to release** workflow from the Actions tab (or `gh workflow run promote.yml -f tag=vx.y.z-rcN`) with the **latest** release candidate of a version newer than the current latest release. It builds static binaries for `x86_64-linux` and `aarch64-linux` at that tag and publishes release `vx.y.z` at the same commit (creating the `vx.y.z` tag), with the notes from the `## [x.y.z]` section of `CHANGELOG.md` on `main`.

The `0.0.0` placeholder is never tagged.

Changes to `main` go through pull requests, which need approval from the code owner.

## Docs

- [GLOSSARY.md](GLOSSARY.md): the terms used throughout (Device, Endpoint, Port, Link, Connection, …)
- [docs/design.md](docs/design.md): design of the rewrite
- [docs/adr/](docs/adr/): architecture decisions

## License

[MIT](LICENSE)
