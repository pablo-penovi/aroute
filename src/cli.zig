//! Output of the non-interactive commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const graph = @import("graph.zig");
const pipewire = @import("pipewire.zig");
const Aliases = @import("aliases.zig").Aliases;

/// `--list`: every Endpoint, the Connections between them, and the snapshot
/// that `--save` would write.
pub fn list(w: *Writer, arena: Allocator, g: graph.Graph) (Writer.Error || Allocator.Error)!void {
    try w.writeAll("DEVICES\n");
    for (g.endpoints, 0..) |ep, i| {
        try w.print("  {d:<4} {t:<5} {t:<5} {t:<4} {s}  [", .{ i, ep.direction, ep.kind, ep.backend, ep.label });
        for (ep.ports, 0..) |port, n| try w.print("{s}{d}", .{ if (n > 0) " " else "", port });
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

test "list: real machine with streams, with aliases" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var g = try pipewire.parse(arena, @embedFile("testdata/pw-dump-streams.json"));
    try g.applyAliases(arena, try Aliases.parse(arena, "aroute-fixture-=\nMiniFuse 1 Main Output L/R=Speakers\n"));

    var out: Writer.Allocating = .init(arena);
    try list(&out.writer, arena, g);
    try testing.expectEqualStrings(
        \\DEVICES
        \\  0    from  audio pw   USB Video Analog Stereo  [73 74]
        \\  1    to    audio pw   Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x]  [78 77]
        \\  2    to    audio pw   MiniFuse 1 Loopback L/R  [81 82]
        \\  3    to    audio pw   Speakers  [87 88]
        \\  4    from  audio pw   MiniFuse 1 Loopback L/R  [91 92]
        \\  5    from  audio pw   MiniFuse 1 Mic/Line/Inst 1 (L)  [97]
        \\  6    to    audio pw   Starship/Matisse HD Audio Controller Digital Stereo (IEC958)  [112 113]
        \\  7    from  audio pw   Starship/Matisse HD Audio Controller Analog Stereo  [116 117]
        \\  8    to    audio pw   rec  [131]
        \\  9    to    audio pw   Renoise Virtual  [158 147]
        \\  10   to    audio pw   mono  [133 161]
        \\  11   from  audio pw   play  [135 138]
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

test "list: empty graph" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try list(&out.writer, testing.allocator, .{ .endpoints = &.{}, .connections = &.{} });
    try testing.expectEqualStrings("DEVICES\nCONNECTIONS\nSNAPSHOT\n", out.written());
}
