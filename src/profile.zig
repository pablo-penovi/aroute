//! Profiles: named, saved sets of Connections, one `<name>.conf` file each in
//! the profiles directory, in the script's format so existing Profiles keep
//! working:
//!
//!     # aroute profile "NAME", saved YYYY-MM-DD HH:MM:SS
//!     # device <audio|midi> <pw:node.name|alsa:client name>=<display label>
//!     # FROM|TO
//!     <FROM port name>|<TO port name>
//!
//! The `# device` lines record each Device's Kind and display name, so a load
//! can say what is missing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const graph = @import("graph.zig");
const Kind = graph.Kind;
const Aliases = @import("aliases.zig").Aliases;

pub const invalid_name = "profile names may only use letters, digits, space, '.', '_' and '-'";

/// Letters, digits, space, `.`, `_` and `-`; at least one.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, " ._-", c) == null) return false;
    }
    return true;
}

pub const Device = struct {
    /// `pw:<node.name>` or `alsa:<client name>`.
    id: []const u8,
    kind: Kind,
    /// Display name, with aliases applied.
    label: []const u8,
};

pub const Profile = struct {
    devices: []const Device,
    /// `FROM|TO` lines, as written.
    lines: []const []const u8,
};

/// Every Device a Link touches, in the order first seen. A Device is `audio`
/// if any of its Connections are. Links are taken Connection by Connection
/// where the script takes them as found; the order only differs if a
/// Connection's Links reach different Devices.
pub fn devices(arena: Allocator, g: graph.Graph, aliases: Aliases) Allocator.Error![]const Device {
    var list: std.ArrayList(Device) = .empty;
    for (g.connections) |c| {
        const kind = g.endpoints[c.from].kind;
        for (c.links) |l| for ([_][]const u8{ l.from_name, l.to_name }) |port| {
            const id = deviceId(port);
            for (list.items) |*d| {
                if (!std.mem.eql(u8, d.id, id)) continue;
                if (kind == .audio) d.kind = .audio;
                break;
            } else try list.append(arena, .{ .id = id, .kind = kind, .label = try aliases.apply(arena, rawLabel(g, id)) });
        };
    }
    return list.items;
}

/// A Port name minus its last `:`-part, as the script's `${id%:*}`.
fn deviceId(port: []const u8) []const u8 {
    return port[0 .. std.mem.findScalarLast(u8, port, ':') orelse port.len];
}

/// A PipeWire node's label, an ALSA client's name; the id without its prefix
/// for a node that is not in the graph.
fn rawLabel(g: graph.Graph, id: []const u8) []const u8 {
    if (std.mem.cutPrefix(u8, id, "pw:")) |name| return g.nodeLabel(name) orelse name;
    return std.mem.cutPrefix(u8, id, "alsa:") orelse id;
}

/// The Profile `name` holding every current Link.
pub fn write(w: *Writer, arena: Allocator, name: []const u8, saved_at: []const u8, g: graph.Graph, aliases: Aliases) (Writer.Error || Allocator.Error)!void {
    try w.print("# aroute profile \"{s}\", saved {s}\n", .{ name, saved_at });
    for (try devices(arena, g, aliases)) |d| try w.print("# device {t} {s}={s}\n", .{ d.kind, d.id, d.label });
    try w.writeAll("# FROM|TO\n");
    for (try g.snapshot(arena)) |line| try w.print("{s}\n", .{line});
}

/// Slices of `source` are kept, so it must outlive the result.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!Profile {
    var devs: std.ArrayList(Device) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (deviceLine(line)) |d| {
            try devs.append(arena, d);
        } else if (line.len > 0 and line[0] != '#') {
            try lines.append(arena, line);
        }
    }
    return .{ .devices = devs.items, .lines = lines.items };
}

/// `# device <audio|midi> <id>=<label>`; the id runs to the first `=`.
fn deviceLine(line: []const u8) ?Device {
    const rest = std.mem.cutPrefix(u8, line, "# device ") orelse return null;
    const space = std.mem.findScalar(u8, rest, ' ') orelse return null;
    const kind = std.meta.stringToEnum(Kind, rest[0..space]) orelse return null;
    const device = rest[space + 1 ..];
    const eq = std.mem.findScalar(u8, device, '=') orelse return null;
    return .{ .id = device[0..eq], .kind = kind, .label = device[eq + 1 ..] };
}

/// The names of the Profiles in `dir`, in the order the script lists them.
pub fn names(arena: Allocator, io: Io, dir: Io.Dir) (Io.Dir.Iterator.Error || Allocator.Error)![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name = std.mem.cutSuffix(u8, entry.name, ".conf") orelse continue;
        if (name.len > 0) try list.append(arena, try arena.dupe(u8, entry.name));
    }
    // Like the script's glob, sorted by file name, `.conf` included.
    std.mem.sort([]const u8, list.items, {}, collate);
    for (list.items) |*n| n.* = n.*[0 .. n.len - ".conf".len];
    return list.items;
}

/// Close to how bash sorts a glob in an en_US.UTF-8 locale, for the
/// characters a Profile file name may hold: by letters and digits alone,
/// ignoring case (`a-b` next to `ab`); then lowercase before uppercase; then
/// with space, `-`, `.`, `_` before letters and digits. glibc's own rules
/// differ only for odd names, e.g. starting with or full of punctuation.
fn collate(_: void, a: []const u8, b: []const u8) bool {
    for ([_]Level{ .letters, .case, .all }) |level| {
        var x: Weights = .{ .s = a, .level = level };
        var y: Weights = .{ .s = b, .level = level };
        switch (Weights.order(&x, &y)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    // Only other characters (not in a valid name) weigh the same.
    return std.mem.lessThan(u8, a, b);
}

const Level = enum { letters, case, all };

/// A string's characters as `collate` weighs them at one level.
const Weights = struct {
    s: []const u8,
    level: Level,
    i: usize = 0,

    /// The next character's weight, or null at the end.
    fn next(w: *Weights) ?u8 {
        while (w.i < w.s.len) {
            const c = w.s[w.i];
            w.i += 1;
            if (std.ascii.isAlphanumeric(c)) return switch (w.level) {
                .letters, .all => 4 + std.ascii.toLower(c),
                .case => @intFromBool(std.ascii.isUpper(c)),
            };
            if (w.level == .all) return @intCast(std.mem.findScalar(u8, " -._", c) orelse 3);
        }
        return null;
    }

    fn order(x: *Weights, y: *Weights) std.math.Order {
        while (true) {
            const cx = x.next() orelse return if (y.next() == null) .eq else .lt;
            const cy = y.next() orelse return .gt;
            if (cx != cy) return std.math.order(cx, cy);
        }
    }
};

const testing = std.testing;
const pipewire = @import("pipewire.zig");
const alsa = @import("alsa.zig");

test "names may only use letters, digits, space, '.', '_' and '-'" {
    for ([_][]const u8{ "Normal idle", "Mic-Line into MorningDAW", "a.b_c", "..", "0" }) |n| try testing.expect(validName(n));
    for ([_][]const u8{ "", "a/b", "../x", "a:b", "tab\there", "ñ", "a|b", "x\n" }) |n| try testing.expect(!validName(n));
}

/// Writes the Profile for a fixture, checks it reads back as the same
/// snapshot and devices, and returns the file.
fn roundTrip(arena: Allocator, g: graph.Graph, aliases: Aliases) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try write(&out.writer, arena, "Test", "2026-11-01 16:45:00", g, aliases);
    const p = try parse(arena, out.written());
    const snap = try g.snapshot(arena);
    try testing.expectEqual(snap.len, p.lines.len);
    for (snap, p.lines) |want, got| try testing.expectEqualStrings(want, got);
    const devs = try devices(arena, g, aliases);
    try testing.expectEqual(devs.len, p.devices.len);
    for (devs, p.devices) |want, got| {
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqualStrings(want.label, got.label);
    }
    return out.written();
}

test "real machine with streams and a split device: same file as the script" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two nodes are named pw-record ("rec" and "mono"): like the script, the
    // later one labels the Device. The split Source is labelled by its node.
    const aliases = try Aliases.parse(arena, "aroute-fixture-=PW \nMiniFuse 1=MF\n");
    var g = try pipewire.parse(arena, @embedFile("testdata/pw-dump-streams.json"), .none);
    try g.applyAliases(arena, aliases);
    try testing.expectEqualStrings(
        \\# aroute profile "Test", saved 2026-11-01 16:45:00
        \\# device audio pw:alsa_input.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Mic__source=MF Mic/Line/Inst 1 (L)
        \\# device audio pw:pw-record=PW mono
        \\# device audio pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo=USB Video Analog Stereo
        \\# device audio pw:pw-play=PW play
        \\# device audio pw:alsa_output.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Line1__sink=MF Main Output L/R
        \\# FROM|TO
        \\pw:alsa_input.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Mic__source:capture_MONO|pw:pw-record:input_MONO
        \\pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_FL|pw:pw-record:input_FL
        \\pw:alsa_input.usb-MACROSILICON_USB_Video-02.analog-stereo:capture_FR|pw:pw-record:input_FR
        \\pw:pw-play:output_FL|pw:alsa_output.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Line1__sink:playback_FL
        \\pw:pw-play:output_FR|pw:alsa_output.usb-ARTURIA_MiniFuse_1_8830400043200514-00.HiFi__Line1__sink:playback_FR
        \\
    , try roundTrip(arena, g, aliases));
}

test "real machine with ALSA MIDI and BLE MIDI: same file as the script" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const midi = try alsa.parse(arena, .{
        .sources = @embedFile("testdata/aconnect-i.txt"),
        .destinations = @embedFile("testdata/aconnect-o.txt"),
        .connections = @embedFile("testdata/aconnect-l.txt"),
    }, false);
    const aliases = try Aliases.parse(arena, "Clipper=M-Vave FM-1\n");
    var g = try pipewire.parse(arena, @embedFile("testdata/pw-dump-midi.json"), midi);
    try g.applyAliases(arena, aliases);
    try testing.expectEqualStrings(
        \\# aroute profile "Test", saved 2026-11-01 16:45:00
        \\# device midi pw:bluez_midi.server=BLE MIDI 1
        \\# device midi alsa:WORLDE=WORLDE
        \\# device midi alsa:Clipper=M-Vave FM-1
        \\# device midi alsa:Keys 'n' Pads=Keys 'n' Pads
        \\# device midi alsa:Midi Through=Midi Through
        \\# FROM|TO
        \\alsa:Clipper:Clipper MIDI 1|pw:bluez_midi.server:in
        \\alsa:Keys 'n' Pads:Keys MIDI 1|alsa:Midi Through:Midi Through Port-0
        \\alsa:Keys 'n' Pads:Keys Sync|alsa:WORLDE:WORLDE MIDI 1
        \\alsa:WORLDE:WORLDE MIDI 1|alsa:Clipper:Clipper MIDI 2
        \\pw:bluez_midi.server:out|alsa:WORLDE:WORLDE MIDI 1
        \\
    , try roundTrip(arena, g, aliases));
}

test "a Device is audio if any of its Connections are; unknown nodes are labelled by name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var endpoints = [_]graph.Endpoint{
        .{ .label = "DAW · midi", .kind = .midi, .direction = .from, .ports = .{ .pw = &.{1} } },
        .{ .label = "Synth", .kind = .midi, .direction = .to, .ports = .{ .pw = &.{2} } },
        .{ .label = "DAW", .kind = .audio, .direction = .from, .ports = .{ .pw = &.{3} } },
        .{ .label = "Out", .kind = .audio, .direction = .to, .ports = .{ .pw = &.{4} } },
    };
    const g: graph.Graph = .{
        .endpoints = &endpoints,
        .connections = &.{
            .{ .from = 0, .to = 1, .links = &.{
                .{ .ends = .{ .pw = .{ 1, 2 } }, .from_name = "pw:daw:midi_out", .to_name = "pw:synth:in" },
            } },
            .{
                .from = 2,
                .to = 3,
                .links = &.{
                    // A port name with a colon: the id is cut at the last one, as in the script.
                    .{ .ends = .{ .pw = .{ 3, 4 } }, .from_name = "pw:daw:out", .to_name = "pw:sink:play:L" },
                },
            },
        },
        .nodes = &.{ .{ .name = "daw", .label = "My DAW" }, .{ .name = "synth", .label = "Synth" } },
    };
    const devs = try devices(arena, g, .none);
    try testing.expectEqual(3, devs.len);
    try testing.expectEqualDeep(Device{ .id = "pw:daw", .kind = .audio, .label = "My DAW" }, devs[0]);
    try testing.expectEqualDeep(Device{ .id = "pw:synth", .kind = .midi, .label = "Synth" }, devs[1]);
    try testing.expectEqualDeep(Device{ .id = "pw:sink:play", .kind = .audio, .label = "sink:play" }, devs[2]);
}

test "no Connections: only the header" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try write(&out.writer, arena_state.allocator(), "Empty", "2026-11-01 16:45:00", .{ .endpoints = &.{}, .connections = &.{} }, .none);
    try testing.expectEqualStrings("# aroute profile \"Empty\", saved 2026-11-01 16:45:00\n# FROM|TO\n", out.written());
}

test "parse: device lines, comments and blank lines" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = try parse(arena_state.allocator(),
        \\# aroute profile "x", saved 2026-10-30 22:50:39
        \\# device audio pw:a=Label=with equals
        \\# device midi alsa:Keys 'n' Pads=Keys
        \\# device video pw:b=not a Kind
        \\# device audio no-equals
        \\# FROM|TO
        \\
        \\pw:a:out|alsa:Keys 'n' Pads:Keys MIDI 1
        \\# a comment
        \\no bar
    );
    try testing.expectEqual(2, p.devices.len);
    try testing.expectEqualDeep(Device{ .id = "pw:a", .kind = .audio, .label = "Label=with equals" }, p.devices[0]);
    try testing.expectEqualDeep(Device{ .id = "alsa:Keys 'n' Pads", .kind = .midi, .label = "Keys" }, p.devices[1]);
    try testing.expectEqual(2, p.lines.len);
    try testing.expectEqualStrings("pw:a:out|alsa:Keys 'n' Pads:Keys MIDI 1", p.lines[0]);
    try testing.expectEqualStrings("no bar", p.lines[1]);
}

test "names: *.conf files, in the script's order" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The order bash's glob gives in en_US.UTF-8.
    const want = [_][]const u8{
        "0.9", "0_9", "09", "10",  "9",   "a1b",   "a 1",   "a.1",    "a1", "A1",       "a  b",       "a b", "a- b", "a-b",
        "a.b", "a_b", "ab", "a c", "ac",  "apple", "Apple", "banana", "B",  "mic line", "Mic-Line x", " x",  "-x",   "_x",
        "x-",  "x",   "x_", "X",   "z-Z", "Z.z",
    };
    for (want) |n| try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}.conf", .{n}), .data = "" });
    for ([_][]const u8{ ".conf", "notes.txt", "x.conf.bak" }) |n| try tmp.dir.writeFile(testing.io, .{ .sub_path = n, .data = "" });

    // Files that are not valid names still get a stable order.
    try testing.expect(collate({}, "a+b.conf", "a_b.conf"));
    try testing.expect(!collate({}, "a_b.conf", "a+b.conf"));

    const got = try names(arena, testing.io, tmp.dir);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}
