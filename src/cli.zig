//! Output of the non-interactive commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const graph = @import("graph.zig");
const pipewire = @import("pipewire.zig");
const alsa = @import("alsa.zig");
const Aliases = @import("aliases.zig").Aliases;

/// `--list`: every Endpoint, the Connections between them, and the snapshot
/// that `--save` would write.
pub fn list(w: *Writer, arena: Allocator, g: graph.Graph) (Writer.Error || Allocator.Error)!void {
    try w.writeAll("DEVICES\n");
    for (g.endpoints, 0..) |ep, i| {
        try w.print("  {d:<4} {t:<5} {t:<5} {t:<4} {s}  [", .{ i, ep.direction, ep.kind, ep.backend(), ep.label });
        switch (ep.ports) {
            .pw => |ports| for (ports, 0..) |port, n| try w.print("{s}{d}", .{ if (n > 0) " " else "", port }),
            .alsa => |port| {
                try w.print("{f}", .{port.addr});
                if (port.bridge) |b| try w.print(" bridge={d}", .{b});
            },
        }
        try w.print("]{s}\n", .{if (ep.hidden) " (hidden)" else ""});
    }
    try w.writeAll("CONNECTIONS\n");
    for (g.connections) |c| {
        try w.print("  {s} → {s}\n", .{ g.endpoints[c.from].label, g.endpoints[c.to].label });
    }
    try w.writeAll("SNAPSHOT\n");
    for (try g.snapshot(arena)) |line| try w.print("  {s}\n", .{line});
}

const testing = std.testing;

test "list: real machine with streams, with aliases, without the ALSA scan" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var g = try pipewire.parse(arena, @embedFile("testdata/pw-dump-streams.json"), .none);
    try g.applyAliases(arena, try Aliases.parse(arena, "aroute-fixture-=\nMiniFuse 1 Main Output L/R=Speakers\n"));

    var out: Writer.Allocating = .init(arena);
    try list(&out.writer, arena, g);
    try testing.expectEqualStrings(
        \\DEVICES
        \\  0    from  audio pw   USB Video Analog Stereo  [73 74]
        \\  1    to    audio pw   Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x]  [78 77]
        \\  2    from  midi  pw   BLE MIDI 1  [54]
        \\  3    to    midi  pw   BLE MIDI 1  [53]
        \\  4    to    audio pw   MiniFuse 1 Loopback L/R  [81 82]
        \\  5    to    audio pw   Speakers  [87 88]
        \\  6    from  audio pw   MiniFuse 1 Loopback L/R  [110 111]
        \\  7    from  audio pw   MiniFuse 1 Mic/Line/Inst 1 (L)  [108]
        \\  8    to    audio pw   Starship/Matisse HD Audio Controller Digital Stereo (IEC958)  [112 113]
        \\  9    from  audio pw   Starship/Matisse HD Audio Controller Analog Stereo  [116 117]
        \\  10   to    audio pw   rec  [131]
        \\  11   from  audio pw   Renoise Virtual  [156 155]
        \\  12   to    audio pw   Renoise Virtual  [158 147]
        \\  13   to    audio pw   mono  [133 161]
        \\  14   from  audio pw   play  [135 138]
        \\  15   from  audio pw   Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x] · monitor  [76 75] (hidden)
        \\  16   from  audio pw   MiniFuse 1 Loopback L/R · monitor  [83 84] (hidden)
        \\  17   from  audio pw   Speakers · monitor  [89 90] (hidden)
        \\  18   from  audio pw   MiniFuse 1 0 · monitor  [104 105 106 107] (hidden)
        \\  19   from  audio pw   MiniFuse 1 0 · capture  [109] (hidden)
        \\  20   from  audio pw   Starship/Matisse HD Audio Controller Digital Stereo (IEC958) · monitor  [114 115] (hidden)
        \\  21   from  audio pw   rec · monitor  [151] (hidden)
        \\  22   from  audio pw   mono · monitor  [146 130] (hidden)
        \\CONNECTIONS
        \\  MiniFuse 1 Mic/Line/Inst 1 (L) → rec
        \\  USB Video Analog Stereo → mono
        \\  play → Speakers
        \\SNAPSHOT
        \\  pw:alsa_input.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Mic__source:capture_MONO|pw:pw-record:input_MONO
        \\  pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_FL|pw:pw-record:input_FL
        \\  pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_FR|pw:pw-record:input_FR
        \\  pw:pw-play:output_FL|pw:alsa_output.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Line1__sink:playback_FL
        \\  pw:pw-play:output_FR|pw:alsa_output.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Line1__sink:playback_FR
        \\
    , out.written());
}

test "list: real machine with ALSA MIDI and BLE MIDI" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Matches the script's --list on the same captures, apart from the snapshot indent.
    const midi = try alsa.parse(arena, .{
        .sources = @embedFile("testdata/aconnect-i.txt"),
        .destinations = @embedFile("testdata/aconnect-o.txt"),
        .connections = @embedFile("testdata/aconnect-l.txt"),
    }, false);
    const g = try pipewire.parse(arena, @embedFile("testdata/pw-dump-midi.json"), midi);

    var out: Writer.Allocating = .init(arena);
    try list(&out.writer, arena, g);
    try testing.expectEqualStrings(
        \\DEVICES
        \\  0    from  midi  alsa Midi Through  [14:0 bridge=55] (hidden)
        \\  1    from  midi  alsa WORLDE  [128:0 bridge=151]
        \\  2    from  midi  alsa Clipper MIDI 1  [129:0 bridge=157]
        \\  3    from  midi  alsa Clipper MIDI 2  [129:1 bridge=156]
        \\  4    from  midi  alsa Keys 'n' Pads  [130:0 bridge=142]
        \\  5    from  midi  alsa Keys 'n' Pads  [130:1 bridge=160] (hidden)
        \\  6    to    midi  alsa Midi Through  [14:0 bridge=54] (hidden)
        \\  7    to    midi  alsa WORLDE  [128:0 bridge=154]
        \\  8    to    midi  alsa Clipper MIDI 1  [129:0 bridge=159]
        \\  9    to    midi  alsa Clipper MIDI 2  [129:1 bridge=146]
        \\  10   to    midi  alsa Keys 'n' Pads  [130:0 bridge=158]
        \\  11   from  audio pw   Renoise Virtual  [46 47]
        \\  12   to    audio pw   Renoise Virtual  [44 45]
        \\  13   from  audio pw   USB Video Analog Stereo  [79 80]
        \\  14   to    audio pw   Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x]  [81 82]
        \\  15   from  midi  pw   BLE MIDI 1  [60]
        \\  16   to    midi  pw   BLE MIDI 1  [59]
        \\  17   to    audio pw   MiniFuse 1 Loopback L/R  [87 88]
        \\  18   to    audio pw   MiniFuse 1 Main Output L/R  [93 94]
        \\  19   from  audio pw   MiniFuse 1 Loopback L/R  [116 117]
        \\  20   from  audio pw   MiniFuse 1 Mic/Line/Inst 1 (L)  [114]
        \\  21   to    audio pw   Starship/Matisse HD Audio Controller Digital Stereo (IEC958)  [118 119]
        \\  22   from  audio pw   Starship/Matisse HD Audio Controller Analog Stereo  [122 123]
        \\  23   from  audio pw   Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x] · monitor  [83 84] (hidden)
        \\  24   from  audio pw   MiniFuse 1 Loopback L/R · monitor  [89 90] (hidden)
        \\  25   from  audio pw   MiniFuse 1 Main Output L/R · monitor  [95 96] (hidden)
        \\  26   from  audio pw   MiniFuse 1 0 · monitor  [110 111 112 113] (hidden)
        \\  27   from  audio pw   MiniFuse 1 0 · capture  [115] (hidden)
        \\  28   from  audio pw   Starship/Matisse HD Audio Controller Digital Stereo (IEC958) · monitor  [120 121] (hidden)
        \\CONNECTIONS
        \\  BLE MIDI 1 → WORLDE
        \\  Clipper MIDI 1 → BLE MIDI 1
        \\  WORLDE → Clipper MIDI 2
        \\  Keys 'n' Pads → Midi Through
        \\  Keys 'n' Pads → WORLDE
        \\SNAPSHOT
        \\  alsa:Clipper:Clipper MIDI 1|pw:bluez_midi.server:in
        \\  alsa:Keys 'n' Pads:Keys MIDI 1|alsa:Midi Through:Midi Through Port-0
        \\  alsa:Keys 'n' Pads:Keys Sync|alsa:WORLDE:WORLDE MIDI 1
        \\  alsa:WORLDE:WORLDE MIDI 1|alsa:Clipper:Clipper MIDI 2
        \\  pw:bluez_midi.server:out|alsa:WORLDE:WORLDE MIDI 1
        \\
    , out.written());
}

test "list: empty graph" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try list(&out.writer, testing.allocator, .{ .endpoints = &.{}, .connections = &.{} });
    try testing.expectEqualStrings("DEVICES\nCONNECTIONS\nSNAPSHOT\n", out.written());
}
