# Talk to PipeWire and ALSA through their command-line tools, for now

aroute reads the graph by parsing `pw-dump` JSON (with Zig's std.json, dropping the old `jq` dependency) and `aconnect` output, and changes it by running `pw-link` and `aconnect`, instead of linking libpipewire/libasound directly. Shelling out keeps the first Zig version a faithful, easily debugged port of the bash script; the cost is polling instead of live graph events. All of it sits behind one module so a native libpipewire/libasound backend can replace it later without touching the TUI.

Superseded for ALSA by [ADR 0002](0002-talk-to-the-alsa-sequencer-through-the-kernel.md), for reading PipeWire in the TUI by [ADR 0003](0003-read-pipewire-in-the-tui-through-pw-dump-monitor.md), and for polling by [ADR 0004](0004-update-the-home-screen-when-the-graph-changes.md).
