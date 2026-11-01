# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.4] - 2026-11-01

### Added

- `aroute --save NAME` saves every current Connection as the Profile `${XDG_CONFIG_HOME:-~/.config}/aroute/profiles/NAME.conf`, in the script's format: the header, a `# device <audio|midi> <id>=<label>` line per Device (`audio` if any of its Connections are, label with aliases applied), then the `FROM|TO` snapshot. An existing Profile is overwritten. Names may only use letters, digits, space, `.`, `_` and `-`. Unlike the script, saving with no Connections reports success.
- `aroute --profiles` lists the saved Profiles, one per line, sorted close to how the script's glob sorts them in an en_US.UTF-8 locale (the same for ordinary names). Unlike the script, names starting with `.` are listed too.

## [0.0.3] - 2026-11-01

### Added

- Split devices (UCM `*.split` loopbacks, e.g. "MiniFuse 1 Main Output L/R"): a split Source reads straight from the hardware Ports behind it, a split sink keeps its own Ports, and Links to those hardware Ports show under the split Endpoint. Links to or from the `.split` loopback itself are not shown.
- Monitor ports of `Audio/Source/Virtual` nodes (null sinks such as "Renoise Virtual") are that node's Source Endpoint.
- Every other Port (raw hardware, other monitors) is in a hidden Endpoint labelled `<node> · <stem>` or `<node> · monitor`, marked `(hidden)` in `--list`, so existing Links to it still show as Connections.

## [0.0.2] - 2026-11-01

### Added

- `aroute --list` shows ALSA MIDI Endpoints read from `aconnect -i`/`-o`, one per sequencer Port and direction, and their Connections from `aconnect -l`. System and `PipeWire-*` clients are skipped. A client with a single visible Port in a direction is labelled by its client name.
- PipeWire MIDI Ports (e.g. BLE MIDI) are Endpoints too, one per port name. Midi-Bridge ports count as the ALSA Port they bridge, so `pw-link` Links between BLE MIDI and an ALSA device show as Connections, with `alsa:<client>:<port>` names in the snapshot.
- `Midi Through` clients and `*Sync` ports are hidden unless `AROUTE_SHOW_ALL=1`.
- `aconnect` is a required dependency. If it fails (e.g. no ALSA sequencer), there is no ALSA MIDI.

## [0.0.1] - 2026-10-31

### Added

- `aroute --list` prints the PipeWire audio Endpoints (one per node, direction and port-name stem), the Connections between them, and the snapshot of `FROM|TO` port names, in the script's format. Unlike the script, every snapshot line is indented and it exits 0 when there are no Connections. MIDI, split devices and hidden Endpoints are not listed yet.
- Display names are rewritten by the `aliases` file, as in the script.
- Design for the Zig rewrite of the `aroute` bash script: on-screen letter picking with paging, per-column search, and parity with the script's CLI and profile format.
- Glossary of domain terms and first architecture decision record.
- Zig build skeleton with `test` and `coverage` (kcov) steps.
- CI (tests, Linux cross-builds, format check) and coverage report on GitHub Pages.
- Release flow: merging a PR tags the merge commit as the next release candidate of the `build.zig.zon` version (`vx.y.z-rcN`); the manually run "Promote tag to release" workflow publishes the latest release candidate of a version newer than the latest release as release `vx.y.z`, with `x86_64-linux` and `aarch64-linux` binaries and notes from this changelog.
