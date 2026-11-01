//! Turns `aconnect -i`, `-o` and `-l` output into ALSA MIDI Endpoints, one per
//! sequencer Port and direction, and the Links between them, as the script's
//! `scan_alsa` and `scan_alsa_links` do.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const Addr = graph.Addr;
const Direction = graph.Direction;

/// What `aconnect` printed.
pub const Output = struct {
    /// `aconnect -i`: Ports that can be read from.
    sources: []const u8 = "",
    /// `aconnect -o`: Ports that can be written to.
    destinations: []const u8 = "",
    /// `aconnect -l`: every Port, with what it is connected to.
    connections: []const u8 = "",
};

/// A Link between two of `Scan.endpoints`.
pub const ScannedLink = struct {
    from: usize,
    to: usize,
    link: graph.Link,
};

pub const Scan = struct {
    /// Sources first, then Destinations, each in `aconnect` order.
    endpoints: []const graph.Endpoint = &.{},
    links: []const ScannedLink = &.{},
    /// `<client name>:<port name>` by address, for naming Ports in profiles.
    names: std.AutoHashMapUnmanaged(Addr, []const u8) = .empty,

    pub const none: Scan = .{};

    /// The Endpoint for that Port and direction, as an index into `endpoints`.
    pub fn find(s: Scan, direction: Direction, addr: Addr) ?usize {
        for (s.endpoints, 0..) |ep, i| {
            if (ep.direction == direction and std.meta.eql(ep.ports.alsa.addr, addr)) return i;
        }
        return null;
    }

    /// `<client name>:<port name>`, or "" for a Port that is not listed (as the script does).
    pub fn name(s: Scan, addr: Addr) []const u8 {
        return s.names.get(addr) orelse "";
    }
};

/// Everything returned is allocated in `arena`, and may point into `out`.
/// `show_all` keeps `Midi Through` clients and `*Sync` ports visible.
pub fn parse(arena: Allocator, out: Output, show_all: bool) Allocator.Error!Scan {
    var scan: Scan = .{};
    var endpoints: std.ArrayList(graph.Endpoint) = .empty;
    // The client name of each Endpoint, for labelling.
    var clients: std.ArrayList([]const u8) = .empty;

    for ([_]struct { []const u8, Direction }{ .{ out.sources, .from }, .{ out.destinations, .to } }) |pass| {
        var client: ?struct { id: u16, name: []const u8 } = null;
        var lines = std.mem.splitScalar(u8, pass[0], '\n');
        while (lines.next()) |line| {
            if (clientLine(line)) |c| {
                if (c.name) |cname| client = .{ .id = c.id, .name = cname };
                continue;
            }
            const p = portLine(line) orelse continue;
            const c = client orelse continue;
            const pname = p.name orelse continue;
            if (c.id == 0 or std.mem.startsWith(u8, c.name, "PipeWire-")) continue;
            const addr: Addr = .{ .client = c.id, .port = p.id };
            try scan.names.put(arena, addr, try std.fmt.allocPrint(arena, "{s}:{s}", .{ c.name, pname }));
            try endpoints.append(arena, .{
                .label = pname,
                .kind = .midi,
                .direction = pass[1],
                .ports = .{ .alsa = .{ .addr = addr } },
                .hidden = !show_all and (std.mem.eql(u8, c.name, "Midi Through") or std.mem.endsWith(u8, pname, "Sync")),
            });
            try clients.append(arena, c.name);
        }
    }

    // A client with a single visible Port in a direction is shown by its
    // client name ("WORLDE"). Like the script, clients are told apart by name.
    for (endpoints.items, clients.items) |*ep, client| {
        var visible: usize = 0;
        for (endpoints.items, clients.items) |other, other_client| {
            if (!other.hidden and other.direction == ep.direction and std.mem.eql(u8, other_client, client)) visible += 1;
        }
        if (visible <= 1) ep.label = client;
    }
    scan.endpoints = endpoints.items;
    scan.links = try parseLinks(arena, scan, out.connections);
    return scan;
}

fn parseLinks(arena: Allocator, scan: Scan, listing: []const u8) Allocator.Error![]const ScannedLink {
    var links: std.ArrayList(ScannedLink) = .empty;
    var client: ?u16 = null;
    var src: ?Addr = null;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (clientLine(line)) |c| {
            client = c.id;
        } else if (portLine(line)) |p| {
            src = if (client) |c| .{ .client = c, .port = p.id } else null;
        } else if (std.mem.find(u8, line, "Connecting To: ")) |at| {
            const s = src orelse continue;
            const from = scan.find(.from, s) orelse continue;
            // `129:1, 145:0[real:1]`
            var dests = std.mem.tokenizeAny(u8, line[at + "Connecting To: ".len ..], ", \t");
            while (dests.next()) |dest| {
                const d = Addr.parse(dest[0 .. std.mem.findScalar(u8, dest, '[') orelse dest.len]) orelse continue;
                const to = scan.find(.to, d) orelse continue;
                try links.append(arena, .{ .from = from, .to = to, .link = .{
                    .ends = .{ .alsa = .{ s, d } },
                    .from_name = try std.fmt.allocPrint(arena, "alsa:{s}", .{scan.name(s)}),
                    .to_name = try std.fmt.allocPrint(arena, "alsa:{s}", .{scan.name(d)}),
                } });
            }
        }
    }
    return links.items;
}

const ClientLine = struct {
    id: u16,
    /// Null when the closing `' [` is missing.
    name: ?[]const u8,
};

/// `client 128: 'WORLDE' [type=kernel,card=2]`. The name runs to the last
/// `' [`, so it may contain quotes.
fn clientLine(line: []const u8) ?ClientLine {
    const rest = std.mem.cutPrefix(u8, line, "client ") orelse return null;
    const colon = std.mem.findScalar(u8, rest, ':') orelse return null;
    const id = graph.number(rest[0..colon]) orelse return null;
    const quoted = std.mem.cutPrefix(u8, rest[colon..], ": '") orelse return null;
    const end = std.mem.findLast(u8, quoted, "' [") orelse return .{ .id = id, .name = null };
    return .{ .id = id, .name = quoted[0..end] };
}

const PortLine = struct {
    id: u16,
    /// Without the padding `aconnect` adds; null when the closing quote is missing.
    name: ?[]const u8,
};

/// `    0 'WORLDE MIDI 1   '`
fn portLine(line: []const u8) ?PortLine {
    const rest = std.mem.trimStart(u8, line, " ");
    if (rest.len == line.len) return null;
    const space = std.mem.findScalar(u8, rest, ' ') orelse return null;
    const id = graph.number(rest[0..space]) orelse return null;
    const quoted = std.mem.cutPrefix(u8, rest[space..], " '") orelse return null;
    const name = if (quoted.len > 0 and quoted[quoted.len - 1] == '\'')
        std.mem.trimEnd(u8, quoted[0 .. quoted.len - 1], " ")
    else
        null;
    return .{ .id = id, .name = name };
}

const testing = std.testing;

const fixture: Output = .{
    .sources = @embedFile("testdata/aconnect-i.txt"),
    .destinations = @embedFile("testdata/aconnect-o.txt"),
    .connections = @embedFile("testdata/aconnect-l.txt"),
};

fn expectEndpoint(ep: graph.Endpoint, label: []const u8, direction: Direction, addr: []const u8, hidden: bool) !void {
    try testing.expectEqualStrings(label, ep.label);
    try testing.expectEqual(direction, ep.direction);
    try testing.expectEqual(graph.Kind.midi, ep.kind);
    try testing.expectEqual(Addr.parse(addr).?, ep.ports.alsa.addr);
    try testing.expectEqual(null, ep.ports.alsa.bridge);
    try testing.expectEqual(hidden, ep.hidden);
}

// The fixture is a real `aconnect` run with three userspace clients standing
// in for USB devices: WORLDE (one port), Clipper (two) and "Keys 'n' Pads"
// (one port plus a read-only Sync port).
test "fixture: one Endpoint per Port and direction, System and PipeWire clients skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), fixture, false);
    try testing.expectEqual(11, s.endpoints.len);
    try expectEndpoint(s.endpoints[0], "Midi Through", .from, "14:0", true);
    try expectEndpoint(s.endpoints[1], "WORLDE", .from, "128:0", false);
    try expectEndpoint(s.endpoints[2], "Clipper MIDI 1", .from, "129:0", false);
    try expectEndpoint(s.endpoints[3], "Clipper MIDI 2", .from, "129:1", false);
    // Sync is hidden, so Keys MIDI 1 is the client's single visible Port.
    try expectEndpoint(s.endpoints[4], "Keys 'n' Pads", .from, "130:0", false);
    try expectEndpoint(s.endpoints[5], "Keys 'n' Pads", .from, "130:1", true);
    try expectEndpoint(s.endpoints[6], "Midi Through", .to, "14:0", true);
    try expectEndpoint(s.endpoints[7], "WORLDE", .to, "128:0", false);
    try expectEndpoint(s.endpoints[8], "Clipper MIDI 1", .to, "129:0", false);
    try expectEndpoint(s.endpoints[9], "Clipper MIDI 2", .to, "129:1", false);
    try expectEndpoint(s.endpoints[10], "Keys 'n' Pads", .to, "130:0", false);

    try testing.expectEqualStrings("Keys 'n' Pads:Keys Sync", s.name(Addr.parse("130:1").?));
    try testing.expectEqualStrings("WORLDE:WORLDE MIDI 1", s.name(Addr.parse("128:0").?));
    try testing.expectEqualStrings("", s.name(Addr.parse("144:0").?));
    try testing.expectEqual(4, s.find(.from, Addr.parse("130:0").?));
    try testing.expectEqual(null, s.find(.to, Addr.parse("130:1").?));
}

test "fixture: AROUTE_SHOW_ALL shows Midi Through and Sync ports" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), fixture, true);
    try testing.expectEqual(11, s.endpoints.len);
    try expectEndpoint(s.endpoints[0], "Midi Through", .from, "14:0", false);
    try expectEndpoint(s.endpoints[4], "Keys MIDI 1", .from, "130:0", false);
    try expectEndpoint(s.endpoints[5], "Keys Sync", .from, "130:1", false);
    try expectEndpoint(s.endpoints[6], "Midi Through", .to, "14:0", false);
    try expectEndpoint(s.endpoints[10], "Keys 'n' Pads", .to, "130:0", false);
}

test "fixture: Links from aconnect -l, between listed Ports only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), fixture, false);
    // System → PipeWire-System and the PipeWire-RT-Event (Midi-Bridge) subscriptions are skipped.
    const want = [_]struct { usize, usize, []const u8, []const u8, []const u8, []const u8 }{
        .{ 1, 9, "128:0", "129:1", "alsa:WORLDE:WORLDE MIDI 1", "alsa:Clipper:Clipper MIDI 2" },
        .{ 4, 6, "130:0", "14:0", "alsa:Keys 'n' Pads:Keys MIDI 1", "alsa:Midi Through:Midi Through Port-0" },
        .{ 5, 7, "130:1", "128:0", "alsa:Keys 'n' Pads:Keys Sync", "alsa:WORLDE:WORLDE MIDI 1" },
    };
    try testing.expectEqual(want.len, s.links.len);
    for (want, s.links) |w, l| {
        try testing.expectEqual(w[0], l.from);
        try testing.expectEqual(w[1], l.to);
        try testing.expectEqual(Addr.parse(w[2]).?, l.link.ends.alsa[0]);
        try testing.expectEqual(Addr.parse(w[3]).?, l.link.ends.alsa[1]);
        try testing.expectEqualStrings(w[4], l.link.from_name);
        try testing.expectEqualStrings(w[5], l.link.to_name);
    }
}

test "a single-port client is labelled per direction, hidden ports not counted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), .{
        .sources =
        \\client 20: 'Pad' [type=kernel,card=1]
        \\    0 'Pad MIDI 1      '
        \\    1 'Pad MIDI 2      '
        \\client 21: 'Midi Through' [type=kernel]
        \\    0 'Midi Through Port-0'
        \\    1 'Midi Through Port-1'
        ,
        .destinations =
        \\client 20: 'Pad' [type=kernel,card=1]
        \\    1 'Pad MIDI 2      '
        ,
    }, false);
    try testing.expectEqual(5, s.endpoints.len);
    try expectEndpoint(s.endpoints[0], "Pad MIDI 1", .from, "20:0", false);
    try expectEndpoint(s.endpoints[1], "Pad MIDI 2", .from, "20:1", false);
    // No visible Port at all: also by client name.
    try expectEndpoint(s.endpoints[2], "Midi Through", .from, "21:0", true);
    try expectEndpoint(s.endpoints[3], "Midi Through", .from, "21:1", true);
    try expectEndpoint(s.endpoints[4], "Pad", .to, "20:1", false);
}

test "lines that are not clients or ports are ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), .{
        .sources = "    0 'before any client'\n" ++
            "client x: 'Bad id' [type=user]\n" ++
            "    0 'still no client'\n" ++
            "client 0: 'System' [type=kernel]\n" ++
            "    0 'Timer           '\n" ++
            "client 24: 'Synth' [type=user,pid=1]\n" ++
            "    0 'no closing quote\n" ++
            "\t1 'tab, not spaces'\n" ++
            "    2 'Synth Out'\n" ++
            "    x 'not a port'\n" ++
            // Not a client line in -i/-o without the closing `' [`: the Port stays Synth's.
            "client 25: 'no bracket'\n" ++
            "    0 'still Synth'\n",
        .destinations = "client 24: 'Synth' [type=user,pid=1]\n" ++
            "    2 'Synth Out'\n",
        .connections = "\tConnecting To: 24:2\n" ++
            "client 24: 'Synth' [type=user,pid=1]\n" ++
            "    2 'Synth Out'\n" ++
            "\tConnecting To: 24:2, 24:9, 99, 24:2[real:0]\n" ++
            "\tConnected From: 24:2\n" ++
            "client y: 'Bad' [type=user]\n" ++
            "    3 'not listed'\n" ++
            "\tConnecting To: 24:2\n" ++
            // In -l it is one, as in the script: this is 25:0, not Synth's 24:0.
            "client 25: 'no bracket'\n" ++
            "    0 'not listed either'\n" ++
            "\tConnecting To: 24:2\n",
    }, false);
    try testing.expectEqual(3, s.endpoints.len);
    try expectEndpoint(s.endpoints[0], "Synth Out", .from, "24:2", false);
    try expectEndpoint(s.endpoints[1], "still Synth", .from, "24:0", false);
    try expectEndpoint(s.endpoints[2], "Synth", .to, "24:2", false);
    try testing.expectEqual(2, s.links.len);
    for (s.links) |l| {
        try testing.expectEqual(0, l.from);
        try testing.expectEqual(2, l.to);
        try testing.expectEqualStrings("alsa:Synth:Synth Out", l.link.to_name);
    }
}

test "no aconnect output, no Endpoints" {
    const s = try parse(testing.allocator, .{}, false);
    try testing.expectEqual(0, s.endpoints.len);
    try testing.expectEqual(0, s.links.len);
}
