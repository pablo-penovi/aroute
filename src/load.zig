//! Loading a Profile, as the script's `plan_profile` and `apply_profile`:
//! work out which of its Connections can be made against a fresh scan and
//! which Devices are missing, then make the whole graph match it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const graph = @import("graph.zig");
const profile = @import("profile.zig");

/// One `FROM|TO` line whose Ports are both present.
pub const Wanted = struct {
    line: []const u8,
    /// How to make the Link: `aconnect` between two ALSA Ports, otherwise
    /// `pw-link`. Null when it cannot be made, e.g. an ALSA Port with no
    /// Midi-Bridge port to a PipeWire one.
    ends: ?graph.Ends,
};

pub const Plan = struct {
    /// In Profile order.
    wanted: []const Wanted,
    /// Display names of the Devices whose Connections are skipped, in Profile
    /// order, each once. A present Device with a missing Port is listed as
    /// `<label> (port <name>)`.
    missing_audio: []const []const u8,
    missing_midi: []const []const u8,
};

/// What loading `p` into `g` would do.
pub fn plan(arena: Allocator, g: graph.Graph, p: profile.Profile) Allocator.Error!Plan {
    var wanted: std.ArrayList(Wanted) = .empty;
    var missing_audio: std.ArrayList([]const u8) = .empty;
    var missing_midi: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (p.lines) |line| {
        const bar = std.mem.findScalar(u8, line, '|');
        const from_name = if (bar) |b| line[0..b] else line;
        const to_name = if (bar) |b| line[b + 1 ..] else line;
        const from = g.port(from_name, .from);
        const to = g.port(to_name, .to);
        if (from != null and to != null) {
            try wanted.append(arena, .{ .line = line, .ends = ends(from.?, to.?) });
            continue;
        }
        // The present end, if any, says the Kind of the missing one.
        const kind = if (to) |t| t.kind else if (from) |f| f.kind else null;
        for ([_]struct { []const u8, bool }{ .{ from_name, from != null }, .{ to_name, to != null } }) |end| {
            if (end[1]) continue;
            const name = end[0];
            const id = deviceId(name);
            const device = p.device(id);
            var label = if (device) |d| d.label else std.mem.cutPrefix(u8, id, "pw:") orelse std.mem.cutPrefix(u8, id, "alsa:") orelse id;
            if (g.hasDevice(id)) label = try std.fmt.allocPrint(arena, "{s} (port {s})", .{ label, portName(name) });
            if ((try seen.getOrPut(arena, label)).found_existing) continue;
            const k = kind orelse if (device) |d| d.kind else if (std.mem.startsWith(u8, id, "alsa:")) graph.Kind.midi else .audio;
            try (if (k == .audio) &missing_audio else &missing_midi).append(arena, label);
        }
    }
    return .{ .wanted = wanted.items, .missing_audio = missing_audio.items, .missing_midi = missing_midi.items };
}

fn ends(from: graph.NamedPort, to: graph.NamedPort) ?graph.Ends {
    if (from.alsa != null and to.alsa != null) return .{ .alsa = .{ from.alsa.?, to.alsa.? } };
    if (from.pw != null and to.pw != null) return .{ .pw = .{ from.pw.?, to.pw.? } };
    return null;
}

/// A Port name minus its last `:`-part, as the script's `${id%:*}`.
fn deviceId(port: []const u8) []const u8 {
    return port[0 .. std.mem.findScalarLast(u8, port, ':') orelse port.len];
}

/// A Port name's last `:`-part, as the script's `${id##*:}`.
fn portName(port: []const u8) []const u8 {
    return port[if (std.mem.findScalarLast(u8, port, ':')) |c| c + 1 else 0..];
}

pub const Result = struct {
    added: usize = 0,
    removed: usize = 0,
    failed: usize = 0,
};

/// Makes `g` match the Profile planned: undoes every Link not wanted, then
/// makes each wanted Link not already there. `wiring` changes the graph,
/// with `connect(graph.Ends)` and `disconnect(graph.Ends)` that fail with
/// `error.ToolFailed` when the tool did not do it.
pub fn apply(arena: Allocator, g: graph.Graph, p: Plan, wiring: anytype) !Result {
    var want: std.StringHashMapUnmanaged(void) = .empty;
    for (p.wanted) |w| try want.put(arena, w.line, {});
    var have: std.StringHashMapUnmanaged(void) = .empty;

    var result: Result = .{};
    for (g.connections) |c| for (c.links) |l| {
        const line = try std.fmt.allocPrint(arena, "{s}|{s}", .{ l.from_name, l.to_name });
        try have.put(arena, line, {});
        if (want.contains(line)) continue;
        if (wiring.disconnect(l.ends)) |_| {
            result.removed += 1;
        } else |err| switch (err) {
            // Like the script, a Link that could not be undone is not reported.
            error.ToolFailed => {},
            else => |e| return e,
        }
    };
    for (p.wanted) |w| {
        if (have.contains(w.line)) continue;
        const e = w.ends orelse {
            result.failed += 1;
            continue;
        };
        if (wiring.connect(e)) |_| {
            result.added += 1;
        } else |err| switch (err) {
            error.ToolFailed => result.failed += 1,
            else => |other| return other,
        }
    }
    return result;
}

/// `✓ Loaded 'NAME': N added, N removed[, N failed][ · skipped (not present): …]`
pub fn summary(w: *Writer, name: []const u8, p: Plan, r: Result) Writer.Error!void {
    try w.print("✓ Loaded '{s}': {d} added, {d} removed", .{ name, r.added, r.removed });
    if (r.failed > 0) try w.print(", {d} failed", .{r.failed});
    var sep: []const u8 = " · skipped (not present): ";
    for ([_][]const []const u8{ p.missing_audio, p.missing_midi }) |missing| for (missing) |m| {
        try w.print("{s}{s}", .{ sep, m });
        sep = ", ";
    };
}

const testing = std.testing;
const pipewire = @import("pipewire.zig");
const alsa = @import("alsa.zig");

/// The real machine with ALSA MIDI, BLE MIDI and audio devices.
fn midiMachine(arena: Allocator) !graph.Graph {
    const midi = try alsa.parse(arena, .{
        .sources = @embedFile("testdata/aconnect-i.txt"),
        .destinations = @embedFile("testdata/aconnect-o.txt"),
        .connections = @embedFile("testdata/aconnect-l.txt"),
    }, false);
    return pipewire.parse(arena, @embedFile("testdata/pw-dump-midi.json"), midi);
}

/// The real machine with audio streams and a split device.
fn streamsMachine(arena: Allocator) !graph.Graph {
    return pipewire.parse(arena, @embedFile("testdata/pw-dump-streams.json"), .none);
}

/// The Profile `--save` would write for `g`, read back.
fn saved(arena: Allocator, g: graph.Graph) !profile.Profile {
    var out: Writer.Allocating = .init(arena);
    try profile.write(&out.writer, arena, "Test", "2026-11-01 16:45:00", g, .none);
    return profile.parse(arena, out.written());
}

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

/// Records what `apply` asks for, and fails the Links in `fail`.
const FakeWiring = struct {
    arena: Allocator,
    fail: []const graph.Ends = &.{},
    connected: std.ArrayList(graph.Ends) = .empty,
    disconnected: std.ArrayList(graph.Ends) = .empty,

    pub fn connect(f: *FakeWiring, e: graph.Ends) error{ ToolFailed, OutOfMemory }!void {
        if (f.fails(e)) return error.ToolFailed;
        try f.connected.append(f.arena, e);
    }

    pub fn disconnect(f: *FakeWiring, e: graph.Ends) error{ ToolFailed, OutOfMemory }!void {
        if (f.fails(e)) return error.ToolFailed;
        try f.disconnected.append(f.arena, e);
    }

    fn fails(f: FakeWiring, e: graph.Ends) bool {
        for (f.fail) |x| if (std.meta.eql(x, e)) return true;
        return false;
    }
};

fn summaryOf(arena: Allocator, p: Plan, r: Result) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try summary(&out.writer, "Test", p, r);
    return out.written();
}

test "everything present: every line wanted, nothing to change" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]graph.Graph{ try midiMachine(arena), try streamsMachine(arena) }) |g| {
        const p = try plan(arena, g, try saved(arena, g));
        try testing.expectEqual(0, p.missing_audio.len);
        try testing.expectEqual(0, p.missing_midi.len);
        const snap = try g.snapshot(arena);
        try testing.expectEqual(snap.len, p.wanted.len);
        for (snap, p.wanted) |line, w| try testing.expectEqualStrings(line, w.line);

        var wiring: FakeWiring = .{ .arena = arena };
        const r = try apply(arena, g, p, &wiring);
        try testing.expectEqual(0, wiring.connected.items.len + wiring.disconnected.items.len);
        try testing.expectEqualStrings("✓ Loaded 'Test': 0 added, 0 removed", try summaryOf(arena, p, r));
    }
}

test "how each wanted Link is made" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try plan(arena, try midiMachine(arena), try profile.parse(arena,
        \\alsa:Clipper:Clipper MIDI 1|pw:bluez_midi.server:in
        \\alsa:WORLDE:WORLDE MIDI 1|alsa:Clipper:Clipper MIDI 2
        \\pw:bluez_midi.server:out|alsa:WORLDE:WORLDE MIDI 1
        \\pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_FL|pw:alsa_output.pci-0000_0d_00.1.hdmi-stereo-extra2:playback_FL
    ));
    try testing.expectEqual(4, p.wanted.len);
    // ALSA to BLE MIDI through the Midi-Bridge, ALSA to ALSA with aconnect.
    try testing.expectEqualDeep(graph.Ends{ .pw = .{ 157, 59 } }, p.wanted[0].ends.?);
    try testing.expectEqualDeep(graph.Ends{ .alsa = .{ .{ .client = 128, .port = 0 }, .{ .client = 129, .port = 1 } } }, p.wanted[1].ends.?);
    try testing.expectEqualDeep(graph.Ends{ .pw = .{ 60, 154 } }, p.wanted[2].ends.?);
    try testing.expectEqualDeep(graph.Ends{ .pw = .{ 79, 81 } }, p.wanted[3].ends.?);
}

test "missing audio device: its Connections are skipped, labelled from the Profile" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try plan(arena, try streamsMachine(arena), try profile.parse(arena,
        \\# aroute profile "Test", saved 2026-11-01 16:45:00
        \\# device audio pw:pw-play=PW play
        \\# device audio pw:alsa_output.usb-Gone=Gone Speakers
        \\# FROM|TO
        \\pw:pw-play:output_FL|pw:alsa_output.usb-Gone:playback_FL
        \\pw:pw-play:output_FR|pw:alsa_output.usb-Gone:playback_FR
        \\pw:gone-stream:out|pw:pw-record:input_MONO
        \\pw:pw-play:output_FL|pw:alsa_output.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Line1__sink:playback_FL
    ));
    // Without a `# device` line, a Device is named by its id.
    try expectStrings(&.{ "Gone Speakers", "gone-stream" }, p.missing_audio);
    try testing.expectEqual(0, p.missing_midi.len);
    try testing.expectEqual(1, p.wanted.len);
}

test "missing MIDI device: Kind from the present end, else the `# device` line, else the backend" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try plan(arena, try midiMachine(arena), try profile.parse(arena,
        \\# device midi pw:gone-synth=Gone Synth
        \\# device audio alsa:Odd=Odd one
        \\alsa:Gone:Gone MIDI 1|alsa:WORLDE:WORLDE MIDI 1
        \\pw:gone-synth:out|pw:other-gone:in
        \\alsa:Odd:Odd 1|alsa:Gone too:in
        \\pw:gone-ble:out|pw:bluez_midi.server:in
    ));
    try testing.expectEqual(0, p.wanted.len);
    try expectStrings(&.{ "other-gone", "Odd one" }, p.missing_audio);
    try expectStrings(&.{ "Gone", "Gone Synth", "Gone too", "gone-ble" }, p.missing_midi);
}

test "present device with a missing Port" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try plan(arena, try midiMachine(arena), try profile.parse(arena,
        \\# device audio pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo=Capture card
        \\# device midi alsa:Clipper=FM-1
        \\pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_RL|pw:alsa_output.pci-0000_0d_00.1.hdmi-stereo-extra2:playback_FL
        \\pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_RL|pw:alsa_output.pci-0000_0d_00.1.hdmi-stereo-extra2:playback_FR
        \\alsa:WORLDE:WORLDE MIDI 1|alsa:Clipper:Clipper MIDI 9
        \\alsa:WORLDE:WORLDE MIDI 1|alsa:WORLDE:WORLDE MIDI 2
    ));
    try testing.expectEqual(0, p.wanted.len);
    try expectStrings(&.{"Capture card (port capture_RL)"}, p.missing_audio);
    try expectStrings(&.{ "FM-1 (port Clipper MIDI 9)", "WORLDE (port WORLDE MIDI 2)" }, p.missing_midi);
}

test "an ALSA Port is looked up in the line's direction; a line without `|` is a Port name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try plan(arena, try midiMachine(arena), try profile.parse(arena,
        \\alsa:Clipper:Clipper MIDI 2|alsa:WORLDE:WORLDE MIDI 1
        \\alsa:WORLDE:WORLDE MIDI 1|alsa:Keys 'n' Pads:Keys Sync
        \\not a line
    ));
    try testing.expectEqual(1, p.wanted.len);
    try testing.expectEqualDeep(graph.Ends{ .alsa = .{ .{ .client = 129, .port = 1 }, .{ .client = 128, .port = 0 } } }, p.wanted[0].ends.?);
    try expectStrings(&.{"Keys 'n' Pads (port Keys Sync)"}, p.missing_midi);
    try expectStrings(&.{"not a line"}, p.missing_audio);
}

test "an ALSA Port without a Midi-Bridge port cannot be wired to a PipeWire one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No Midi-Bridge for WORLDE in this dump.
    const midi = try alsa.parse(arena, .{
        .sources = @embedFile("testdata/aconnect-i.txt"),
        .destinations = @embedFile("testdata/aconnect-o.txt"),
    }, false);
    const g = try pipewire.parse(arena, @embedFile("testdata/pw-dump-streams.json"), midi);
    const p = try plan(arena, g, try profile.parse(arena, "pw:bluez_midi.server:out|alsa:WORLDE:WORLDE MIDI 1\n"));
    try testing.expectEqual(1, p.wanted.len);
    try testing.expectEqual(null, p.wanted[0].ends);

    var wiring: FakeWiring = .{ .arena = arena };
    try testing.expectEqualDeep(Result{ .failed = 1, .removed = 5 }, try apply(arena, g, p, &wiring));
    try testing.expectEqual(0, wiring.connected.items.len);
}

test "apply: undoes Links not wanted, makes the missing ones, counts failures" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Current: the five MIDI Links in the fixture. Wanted: one of them, two
    // new ones (one of which fails), and Links to missing Devices.
    const g = try midiMachine(arena);
    const p = try plan(arena, g, try profile.parse(arena,
        \\# device audio pw:alsa_output.usb-Gone=Gone Speakers
        \\alsa:WORLDE:WORLDE MIDI 1|alsa:Clipper:Clipper MIDI 2
        \\alsa:Clipper:Clipper MIDI 1|alsa:WORLDE:WORLDE MIDI 1
        \\pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_FL|pw:alsa_output.pci-0000_0d_00.1.hdmi-stereo-extra2:playback_FL
        \\pw:pw-play:output_FL|pw:alsa_output.usb-Gone:playback_FL
    ));
    try testing.expectEqual(3, p.wanted.len);

    var wiring: FakeWiring = .{
        .arena = arena,
        .fail = &.{
            .{ .pw = .{ 79, 81 } },
            // Could not undo Keys MIDI 1 → Midi Through: not counted.
            .{ .alsa = .{ .{ .client = 130, .port = 0 }, .{ .client = 14, .port = 0 } } },
        },
    };
    const r = try apply(arena, g, p, &wiring);
    try testing.expectEqualDeep(Result{ .added = 1, .removed = 3, .failed = 1 }, r);
    try testing.expectEqualDeep(&[_]graph.Ends{.{ .alsa = .{ .{ .client = 129, .port = 0 }, .{ .client = 128, .port = 0 } } }}, wiring.connected.items);
    try testing.expectEqualDeep(&[_]graph.Ends{
        .{ .pw = .{ 60, 154 } },
        .{ .pw = .{ 157, 59 } },
        .{ .alsa = .{ .{ .client = 130, .port = 1 }, .{ .client = 128, .port = 0 } } },
    }, wiring.disconnected.items);
    try testing.expectEqualStrings(
        "✓ Loaded 'Test': 1 added, 3 removed, 1 failed · skipped (not present): pw-play, Gone Speakers",
        try summaryOf(arena, p, r),
    );
}

test "apply: other errors stop it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Missing = struct {
        pub fn connect(_: @This(), _: graph.Ends) error{ ToolFailed, MissingTool }!void {
            return error.MissingTool;
        }
        pub fn disconnect(_: @This(), _: graph.Ends) error{ ToolFailed, MissingTool }!void {
            return error.MissingTool;
        }
    };
    // Undoing a Link, and making one.
    const g = try midiMachine(arena);
    try testing.expectError(error.MissingTool, apply(arena, g, try plan(arena, g, .{ .devices = &.{}, .lines = &.{} }), Missing{}));
    const empty: graph.Graph = .{ .endpoints = &.{}, .connections = &.{} };
    const one: Plan = .{ .wanted = &.{.{ .line = "a|b", .ends = .{ .pw = .{ 1, 2 } } }}, .missing_audio = &.{}, .missing_midi = &.{} };
    try testing.expectError(error.MissingTool, apply(arena, empty, one, Missing{}));
}

test "summary: missing MIDI after missing audio" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p: Plan = .{ .wanted = &.{}, .missing_audio = &.{"A"}, .missing_midi = &.{ "M1", "M2" } };
    try testing.expectEqualStrings(
        "✓ Loaded 'Test': 2 added, 0 removed · skipped (not present): A, M1, M2",
        try summaryOf(arena_state.allocator(), p, .{ .added = 2 }),
    );
}
