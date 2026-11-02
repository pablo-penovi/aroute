# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.8] - 2026-11-01

### Added

- `2` Disconnect in the TUI: the CONNECTIONS list with a letter on each row, in place of the columns. Picking one removes all of its Links (`pw-link -d` / `aconnect -d`); the status line then says `✓ Disconnected Source → Destination`, or `✗ could not fully disconnect Source → Destination` if a Link could not be removed.
- When the list doesn't fit, `PgUp`/`PgDn` page through it and the letters go to the new rows, as in Connect; the header shows `CONNECTIONS  2/3` and the menu `PgUp/PgDn Page`.
- While picking, the graph is not re-read. Just before disconnecting it is, and every Link the Connection has by then is removed; if it is no longer there, the status says `✗ Source → Destination is gone` instead.

### Changed

- Unlike the script, there is no limit of 52 Connections that can be picked.

## [0.0.7] - 2026-11-01

### Added

- `1` Connect in the TUI. Step 1 picks a device, step 2 the other end; the status line then says `✓ Source → Destination`, or `✗ Source → Destination: <what pw-link or aconnect said>`. Audio channels are paired as in the script: a mono Port fans out, matching channel positions pair up, otherwise they pair in order. MIDI between two ALSA Ports uses `aconnect`, otherwise `pw-link`, through the Midi-Bridge for ALSA MIDI.
- Only the focused column has letters, always `a`… from the top (`a`–`z`, `A`–`Z`) and only on rows on screen; the other column is dimmed. Focus starts on FROM, and `Tab` switches to TO, so you can start from a Destination. In step 2 focus moves to the other column, which lists only what the first pick can be connected to (same Kind, not connected yet, ALSA to PipeWire only through a Midi-Bridge port); the first pick is shown in reverse video.
- When a column doesn't fit, `PgUp`/`PgDn` page through it and the letters go to the new rows. A page is as many rows as fit, at most 52; the header shows `FROM  2/3` and the menu `PgUp/PgDn Page`.
- While picking, the CONNECTIONS list is a one-line summary (`7 connections`) and the graph is not re-read. Just before connecting it is, and if a pick is no longer there the status says `✗ … is gone` instead.

### Changed

- Unlike the script, rows that can't be picked are left out of the focused column instead of shown without a letter, there is no limit of 52 pickable rows, and `Esc` in step 2 goes back to step 1 (a second `Esc` goes home) instead of straight home.

## [0.0.6] - 2026-11-01

### Added

- `aroute` with no arguments starts the TUI on its home screen, as the script draws it: the title with the current Profile (`default` at startup) and a red `(modified)` once the Connections differ from the ones it was loaded or saved with, the `● audio` / `● MIDI` legend, the FROM and TO columns (audio before MIDI, hidden Endpoints left out), the CONNECTIONS list coloured by Kind, the menu and the status line. The graph is re-read every second, Esc quits, and the menu's other keys say they are not implemented yet.
- The terminal is put back as it was on Esc, on Ctrl-C or SIGTERM (exit status 130, as in the script) and on errors. Without a terminal, the TUI doesn't start: `the TUI needs a terminal (see --help for non-interactive use)`.
- When the home screen doesn't fit, `PgUp`/`PgDn` scroll it, with `↑ N more (PgUp)` / `↓ N more (PgDn)` rows saying what is left out. The script instead cuts it off with `… N more (enlarge the terminal)`.
- It redraws when the terminal is resized. Names are cut with `…` by display width, so wide (e.g. CJK) characters and combining marks line up, and no row is wider than the terminal, menu and title included (the script lets those wrap).
- If the graph can't be re-read, the last one stays on screen and the status line says `✗ cannot read the PipeWire graph (is PipeWire running?)` until a read works again.

## [0.0.5] - 2026-11-01

### Added

- `aroute --load NAME [--force]` makes the whole graph match a Profile, as the script does: every current Link not in it is undone, then each of its Links that is not there yet is made (`aconnect` between two ALSA Ports, otherwise `pw-link`, through the Midi-Bridge for ALSA MIDI; one that already exists counts as made). It prints `✓ Loaded 'NAME': N added, N removed[, N failed][ · skipped (not present): …]`, naming each missing Device by its `# device` label, or `<label> (port <name>)` when only a Port is missing.
- If audio Devices from the Profile are missing, they are listed on stderr; `--force` hooks up only the available Connections, on a terminal you are asked `Continue and hook up only the available connections? [y/N]`, and otherwise nothing is loaded. Missing MIDI Devices alone never block.

### Changed

- Every command first checks that `pw-dump`, `pw-link` and `aconnect` are installed (on `PATH` and executable), as the script does. If any is missing, aroute names them, says which package to install (PipeWire's tools or `alsa-utils`), and exits 1.

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
