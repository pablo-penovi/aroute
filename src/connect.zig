//! Making a Connection, as the script's `valid_pair`, `has_partner`,
//! `map_channels` and `connect_eps`: which Endpoints can be connected, and
//! which Links connect them; and finding Endpoints and Connections again in
//! another read of the graph.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const Endpoint = graph.Endpoint;

/// Whether the Source `from` can be connected to the Destination `to`: same
/// Kind, not connected yet, and ALSA to PipeWire only through a Midi-Bridge port.
pub fn validPair(g: Graph, from: usize, to: usize) bool {
    const f = g.endpoints[from];
    const t = g.endpoints[to];
    if (f.direction != .from or t.direction != .to) return false;
    if (f.kind != t.kind) return false;
    if (g.connection(from, to) != null) return false;
    if (f.backend() != t.backend()) {
        if (f.ports == .alsa and f.ports.alsa.bridge == null) return false;
        if (t.ports == .alsa and t.ports.alsa.bridge == null) return false;
    }
    return true;
}

/// Whether `a` and `b` can be connected, whichever is the Source.
pub fn validEither(g: Graph, a: usize, b: usize) bool {
    return if (g.endpoints[a].direction == .from) validPair(g, a, b) else validPair(g, b, a);
}

/// Whether `ep` can be connected to some Endpoint shown in a column.
pub fn hasPartner(g: Graph, ep: usize) bool {
    for (g.endpoints, 0..) |o, i| {
        if (!o.hidden and validEither(g, ep, i)) return true;
    }
    return false;
}

/// `ep` in another read of the graph: the Endpoint with the same label, Kind,
/// direction, Ports and hiddenness. Null if it is gone.
pub fn find(g: Graph, ep: Endpoint) ?usize {
    for (g.endpoints, 0..) |o, i| {
        if (o.hidden != ep.hidden or o.kind != ep.kind or o.direction != ep.direction) continue;
        if (!std.mem.eql(u8, o.label, ep.label)) continue;
        const same = switch (ep.ports) {
            .pw => |p| o.ports == .pw and std.mem.eql(u32, o.ports.pw, p),
            .alsa => |a| o.ports == .alsa and std.meta.eql(o.ports.alsa.addr, a.addr),
        };
        if (same) return i;
    }
    return null;
}

/// The Connection from `from` to `to` in another read of the graph, both
/// found as by `find`. Null if either is gone, or they are no longer connected.
pub fn findConnection(g: Graph, from: Endpoint, to: Endpoint) ?graph.Connection {
    return g.connection(find(g, from) orelse return null, find(g, to) orelse return null);
}

pub const Error = error{
    /// One side has no Ports to wire through `pw-link`.
    NoRoutablePorts,
} || Allocator.Error;

/// The Links that connect the Source `from` to the Destination `to`: one
/// `aconnect` between two ALSA Ports, otherwise `pw-link`s between their
/// PipeWire Ports (an ALSA Port's being its Midi-Bridge port), paired by
/// `pairChannels`.
pub fn links(arena: Allocator, g: Graph, from: usize, to: usize) Error![]const graph.Ends {
    const f = g.endpoints[from].ports;
    const t = g.endpoints[to].ports;
    if (f == .alsa and t == .alsa) {
        const one = try arena.alloc(graph.Ends, 1);
        one[0] = .{ .alsa = .{ f.alsa.addr, t.alsa.addr } };
        return one;
    }
    const a = try pwPorts(arena, f);
    const b = try pwPorts(arena, t);
    if (a.len == 0 or b.len == 0) return error.NoRoutablePorts;
    const pairs = try pairChannels(arena, g, a, b);
    const out = try arena.alloc(graph.Ends, pairs.len);
    for (pairs, out) |p, *o| o.* = .{ .pw = p };
    return out;
}

fn pwPorts(arena: Allocator, ports: graph.Ports) Allocator.Error![]const u32 {
    return switch (ports) {
        .pw => |p| p,
        .alsa => |a| if (a.bridge) |b| try arena.dupe(u32, &.{b}) else &.{},
    };
}

/// Pairs Source Ports `a` with Destination Ports `b`, as the script's
/// `map_channels`: a single Port on either side fans out to every Port on
/// the other; otherwise, if every Port in `a` has a channel position found
/// in `b`, each goes to the first with the same one; otherwise they pair
/// up in order, as many as the shorter side has.
pub fn pairChannels(arena: Allocator, g: Graph, a: []const u32, b: []const u32) Allocator.Error![]const [2]u32 {
    var out: std.ArrayList([2]u32) = .empty;
    if (a.len == 1) {
        for (b) |y| try out.append(arena, .{ a[0], y });
        return out.items;
    }
    if (b.len == 1) {
        for (a) |x| try out.append(arena, .{ x, b[0] });
        return out.items;
    }
    by_position: {
        for (a) |x| {
            const position = g.channel(x);
            if (position.len == 0) break :by_position;
            const y = for (b) |y| {
                if (std.mem.eql(u8, g.channel(y), position)) break y;
            } else break :by_position;
            try out.append(arena, .{ x, y });
        }
        return out.items;
    }
    out.clearRetainingCapacity();
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| try out.append(arena, .{ x, y });
    return out.items;
}

const testing = std.testing;

fn pw(label: []const u8, kind: graph.Kind, direction: graph.Direction, ports: []const u32) Endpoint {
    return .{ .label = label, .kind = kind, .direction = direction, .ports = .{ .pw = ports } };
}

fn alsaEp(label: []const u8, direction: graph.Direction, client: u16, bridge: ?u32) Endpoint {
    return .{ .label = label, .kind = .midi, .direction = direction, .ports = .{ .alsa = .{ .addr = .{ .client = client, .port = 0 }, .bridge = bridge } } };
}

var pair_eps = [_]Endpoint{
    pw("Mic", .audio, .from, &.{1}), // 0
    pw("Speakers", .audio, .to, &.{ 2, 3 }), // 1
    pw("Headphones", .audio, .to, &.{ 4, 5 }), // 2
    pw("BLE MIDI", .midi, .from, &.{6}), // 3
    pw("BLE MIDI", .midi, .to, &.{7}), // 4
    alsaEp("Keys", .from, 128, 60), // 5
    alsaEp("Synth", .to, 129, null), // 6
    alsaEp("Drums", .to, 130, 61), // 7
    pw("Speakers · monitor", .audio, .from, &.{ 8, 9 }), // 8
};

const pair_graph: Graph = .{
    .endpoints = &pair_eps,
    .connections = &.{.{ .from = 0, .to = 2, .links = &.{} }},
};

test "validPair: Source to Destination of the same Kind, not connected yet" {
    try testing.expect(validPair(pair_graph, 0, 1));
    // Already connected.
    try testing.expect(!validPair(pair_graph, 0, 2));
    // Wrong way round, two Sources, two Destinations.
    try testing.expect(!validPair(pair_graph, 1, 0));
    try testing.expect(!validPair(pair_graph, 0, 3));
    try testing.expect(!validPair(pair_graph, 1, 2));
    // Audio to MIDI.
    try testing.expect(!validPair(pair_graph, 0, 4));
    try testing.expect(!validPair(pair_graph, 3, 1));
    // MIDI to MIDI, either backend.
    try testing.expect(validPair(pair_graph, 3, 4));
    try testing.expect(validPair(pair_graph, 5, 6));
    try testing.expect(validPair(pair_graph, 5, 7));
}

test "validPair: ALSA to PipeWire only through a Midi-Bridge port" {
    // Keys has a bridge; Synth has none, Drums has one.
    try testing.expect(validPair(pair_graph, 5, 4));
    try testing.expect(!validPair(pair_graph, 3, 6));
    try testing.expect(validPair(pair_graph, 3, 7));
    var eps = pair_eps;
    eps[5].ports.alsa.bridge = null;
    const g: Graph = .{ .endpoints = &eps, .connections = &.{} };
    try testing.expect(!validPair(g, 5, 4));
    // ALSA to ALSA needs no bridge.
    try testing.expect(validPair(g, 5, 6));
}

test "validEither and hasPartner: either way round, visible partners only" {
    try testing.expect(validEither(pair_graph, 1, 0));
    try testing.expect(validEither(pair_graph, 0, 1));
    try testing.expect(!validEither(pair_graph, 2, 0));
    try testing.expect(hasPartner(pair_graph, 0));
    try testing.expect(hasPartner(pair_graph, 2));
    try testing.expect(hasPartner(pair_graph, 6));

    // Mic's only partners: Speakers (connected) and the hidden monitor's
    // Destinations; a hidden Destination does not count.
    var eps = [_]Endpoint{
        pw("Mic", .audio, .from, &.{1}),
        pw("Speakers", .audio, .to, &.{2}),
        pw("Raw", .audio, .to, &.{3}),
        pw("Keys", .midi, .to, &.{4}),
    };
    eps[2].hidden = true;
    const g: Graph = .{ .endpoints = &eps, .connections = &.{.{ .from = 0, .to = 1, .links = &.{} }} };
    try testing.expect(!hasPartner(g, 0));
    try testing.expect(!hasPartner(g, 1));
    try testing.expect(!hasPartner(g, 3));
}

test "find: the same Endpoint in another read, or null if it is gone" {
    var eps = [_]Endpoint{
        pw("Speakers", .audio, .to, &.{ 2, 3 }),
        pw("Mic", .audio, .from, &.{1}),
        alsaEp("Keys", .from, 128, null),
        pw("Speakers", .audio, .to, &.{ 12, 13 }),
    };
    const g: Graph = .{ .endpoints = &eps, .connections = &.{} };
    try testing.expectEqual(1, find(g, pair_eps[0]));
    try testing.expectEqual(0, find(g, pair_eps[1]));
    // The Midi-Bridge port may come and go; the ALSA Port is the same.
    try testing.expectEqual(2, find(g, pair_eps[5]));
    // Same label, other Ports (replugged); other label; other direction.
    try testing.expectEqual(null, find(g, pw("Speakers", .audio, .to, &.{ 2, 4 })));
    try testing.expectEqual(null, find(g, pw("Mic 2", .audio, .from, &.{1})));
    try testing.expectEqual(null, find(g, pw("Mic", .audio, .to, &.{1})));
    try testing.expectEqual(null, find(g, pair_eps[6]));
}

test "find: a hidden Endpoint only as a hidden one" {
    var monitor = pw("Speakers · monitor", .audio, .from, &.{ 8, 9 });
    monitor.hidden = true;
    var eps = [_]Endpoint{ pair_eps[8], monitor };
    const g: Graph = .{ .endpoints = &eps, .connections = &.{} };
    try testing.expectEqual(1, find(g, monitor));
    try testing.expectEqual(0, find(g, pair_eps[8]));
}

test "findConnection: the same Connection in another read, with its Links then" {
    const links_then = [_]graph.Link{.{ .ends = .{ .pw = .{ 11, 14 } }, .from_name = "pw:mic:out", .to_name = "pw:hp:in_FL" }};
    // The same Endpoints as in `pair_eps`, at other indexes.
    var eps = [_]Endpoint{ pair_eps[2], pair_eps[1], pair_eps[0] };
    const g: Graph = .{ .endpoints = &eps, .connections = &.{
        .{ .from = 2, .to = 1, .links = &.{} },
        .{ .from = 2, .to = 0, .links = &links_then },
    } };
    try testing.expectEqual(&links_then, findConnection(g, pair_eps[0], pair_eps[2]).?.links.ptr);
    try testing.expectEqual(1, findConnection(g, pair_eps[0], pair_eps[1]).?.to);
    // Not connected any more.
    var unlinked = g;
    unlinked.connections = g.connections[0..1];
    try testing.expectEqual(null, findConnection(unlinked, pair_eps[0], pair_eps[2]));
    // One side gone.
    try testing.expectEqual(null, findConnection(g, pw("Mic 2", .audio, .from, &.{1}), pair_eps[1]));
    try testing.expectEqual(null, findConnection(g, pair_eps[0], pw("Speakers", .audio, .to, &.{ 2, 9 })));
}

/// A graph whose PipeWire Ports have these channel positions, by id.
fn withChannels(comptime positions: []const struct { u32, []const u8 }) Graph {
    const ports = comptime blk: {
        var ps: [positions.len]graph.NamedPort = undefined;
        for (positions, &ps) |p, *n| n.* = .{ .name = "", .direction = .from, .kind = .audio, .pw = p[0], .channel = p[1] };
        const final = ps;
        break :blk &final;
    };
    return .{ .endpoints = &.{}, .connections = &.{}, .ports = ports };
}

test "pairChannels: mono fans out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = withChannels(&.{ .{ 1, "MONO" }, .{ 2, "FL" }, .{ 3, "FR" } });
    try testing.expectEqualSlices([2]u32, &.{ .{ 1, 2 }, .{ 1, 3 } }, try pairChannels(arena, g, &.{1}, &.{ 2, 3 }));
    try testing.expectEqualSlices([2]u32, &.{ .{ 2, 1 }, .{ 3, 1 } }, try pairChannels(arena, g, &.{ 2, 3 }, &.{1}));
    try testing.expectEqualSlices([2]u32, &.{.{ 1, 1 }}, try pairChannels(arena, g, &.{1}, &.{1}));
}

test "pairChannels: stereo to stereo by channel position" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Destination Ports listed FR first; the extra AUX0 is left out.
    const g = withChannels(&.{ .{ 1, "FL" }, .{ 2, "FR" }, .{ 11, "FR" }, .{ 12, "AUX0" }, .{ 13, "FL" } });
    try testing.expectEqualSlices([2]u32, &.{ .{ 1, 13 }, .{ 2, 11 } }, try pairChannels(arena, g, &.{ 1, 2 }, &.{ 11, 12, 13 }));
}

test "pairChannels: by order when positions are missing or don't match" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = withChannels(&.{
        .{ 1, "FL" },    .{ 2, "FR" },    .{ 3, "" },      .{ 4, "" },
        .{ 11, "AUX0" }, .{ 12, "AUX1" }, .{ 13, "AUX2" }, .{ 14, "FL" },
    });
    // No position matches FR.
    try testing.expectEqualSlices([2]u32, &.{ .{ 1, 11 }, .{ 2, 12 } }, try pairChannels(arena, g, &.{ 1, 2 }, &.{ 11, 12, 14 }));
    // A Source Port with no position.
    try testing.expectEqualSlices([2]u32, &.{ .{ 3, 14 }, .{ 4, 11 } }, try pairChannels(arena, g, &.{ 3, 4 }, &.{ 14, 11 }));
    // As many as the shorter side.
    try testing.expectEqualSlices([2]u32, &.{ .{ 11, 1 }, .{ 12, 2 } }, try pairChannels(arena, g, &.{ 11, 12, 13 }, &.{ 1, 2 }));
    // Nothing to pair with.
    try testing.expectEqual(0, (try pairChannels(arena, g, &.{ 1, 2 }, &.{})).len);
}

test "links: aconnect between ALSA Ports, pw-link through the Midi-Bridge otherwise" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualDeep(&[_]graph.Ends{.{ .alsa = .{ .{ .client = 128, .port = 0 }, .{ .client = 129, .port = 0 } } }}, try links(arena, pair_graph, 5, 6));
    try testing.expectEqualDeep(&[_]graph.Ends{.{ .pw = .{ 60, 7 } }}, try links(arena, pair_graph, 5, 4));
    try testing.expectEqualDeep(&[_]graph.Ends{.{ .pw = .{ 6, 61 } }}, try links(arena, pair_graph, 3, 7));
    try testing.expectEqualDeep(&[_]graph.Ends{ .{ .pw = .{ 1, 2 } }, .{ .pw = .{ 1, 3 } } }, try links(arena, pair_graph, 0, 1));
    // No bridge; no Ports at all.
    try testing.expectError(error.NoRoutablePorts, links(arena, pair_graph, 3, 6));
    var eps = [_]Endpoint{ pw("Empty", .audio, .from, &.{}), pw("Speakers", .audio, .to, &.{2}) };
    try testing.expectError(error.NoRoutablePorts, links(arena, .{ .endpoints = &eps, .connections = &.{} }, 0, 1));
}

test "links: a real stereo Source to a real stereo Destination" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = try @import("pipewire.zig").parse(arena, @embedFile("testdata/pw-dump-idle.json"), .none);
    const from = for (g.endpoints, 0..) |ep, i| {
        if (std.mem.eql(u8, ep.label, "USB Video Analog Stereo")) break i;
    } else return error.TestUnexpectedResult;
    const to = for (g.endpoints, 0..) |ep, i| {
        if (ep.direction == .to and std.mem.startsWith(u8, ep.label, "Navi 21/23")) break i;
    } else return error.TestUnexpectedResult;
    try testing.expect(validPair(g, from, to));
    // capture_FL → playback_FL (78), capture_FR → playback_FR (77).
    try testing.expectEqualDeep(&[_]graph.Ends{ .{ .pw = .{ 73, 78 } }, .{ .pw = .{ 74, 77 } } }, try links(arena, g, from, to));
}
