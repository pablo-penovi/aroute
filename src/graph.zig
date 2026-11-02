//! The graph as aroute sees it: Endpoints, and the Connections between them.
//! Terms are defined in GLOSSARY.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Aliases = @import("aliases.zig").Aliases;

/// Source (FROM column) or Destination (TO column).
pub const Direction = enum { from, to };

pub const Kind = enum { audio, midi };

/// Which tool the Endpoint's Ports are wired through.
pub const Backend = enum { pw, alsa };

/// An ALSA sequencer Port, as `aconnect` writes it: `client:port`.
pub const Addr = struct {
    client: u16,
    port: u16,

    /// `128:0`; null for anything else.
    pub fn parse(s: []const u8) ?Addr {
        const colon = std.mem.findScalar(u8, s, ':') orelse return null;
        return .{
            .client = number(s[0..colon]) orelse return null,
            .port = number(s[colon + 1 ..]) orelse return null,
        };
    }

    pub fn format(a: Addr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}", .{ a.client, a.port });
    }
};

/// Digits only, no sign: what the script's `[0-9]+` accepts.
pub fn number(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

pub const Ports = union(Backend) {
    /// PipeWire port ids, in port order.
    pw: []const u32,
    alsa: struct {
        addr: Addr,
        /// The Midi-Bridge's PipeWire port for it, through which it is wired
        /// to PipeWire-only MIDI Ports (e.g. BLE MIDI).
        bridge: ?u32 = null,
    },
};

pub const Endpoint = struct {
    /// Display name, with aliases applied once `Graph.applyAliases` has run.
    label: []const u8,
    kind: Kind,
    direction: Direction,
    /// Which tool its Ports are wired through, and their ids in that tool.
    ports: Ports,
    /// Kept so existing Links to it can be shown and undone, but never offered in a column.
    hidden: bool = false,

    pub fn backend(ep: Endpoint) Backend {
        return ep.ports;
    }
};

/// The Source-side and Destination-side Port of a Link: what `pw-link` or
/// `aconnect` take to make it, or with `-d` to undo it.
pub const Ends = union(Backend) {
    pw: [2]u32,
    alsa: [2]Addr,
};

/// One Port-to-Port wire.
pub const Link = struct {
    ends: Ends,
    /// Port names as stored in profiles: `pw:<node.name>:<port.name>` or
    /// `alsa:<client name>:<port name>`.
    from_name: []const u8,
    to_name: []const u8,
};

/// All the Links between one Source and one Destination.
pub const Connection = struct {
    /// Indexes into `Graph.endpoints`.
    from: usize,
    to: usize,
    links: []const Link,
};

/// A PipeWire node's display name, by `node.name`: how profiles label a Device.
pub const Node = struct {
    name: []const u8,
    /// Without aliases: profiles apply them to the whole Device label.
    label: []const u8,
};

/// A Port by the name profiles give it, and how to wire it.
pub const NamedPort = struct {
    /// `pw:<node.name>:<port.name>` or `alsa:<client name>:<port name>`.
    name: []const u8,
    direction: Direction,
    kind: Kind,
    /// Its PipeWire port id; for an ALSA Port, its Midi-Bridge port, if any.
    pw: ?u32,
    /// ALSA Ports only.
    alsa: ?Addr = null,
    /// A PipeWire audio Port's channel position (`FL`, `MONO`, `AUX0`, …),
    /// for pairing channels; empty if it has none.
    channel: []const u8 = "",
};

pub const Graph = struct {
    endpoints: []Endpoint,
    /// In the order their first Link was found.
    connections: []const Connection,
    /// Every PipeWire node with Ports, one per `node.name` (as the script's
    /// NODE_BYNAME, the last one in port order when several share a name).
    nodes: []const Node = &.{},
    /// Every ALSA Port (one per direction) and every PipeWire Port other than
    /// Midi-Bridge ones, which go by their ALSA Port's name.
    ports: []const NamedPort = &.{},

    pub fn applyAliases(g: *Graph, arena: Allocator, aliases: Aliases) Allocator.Error!void {
        for (g.endpoints) |*ep| ep.label = try aliases.apply(arena, ep.label);
    }

    pub fn nodeLabel(g: Graph, name: []const u8) ?[]const u8 {
        for (g.nodes) |n| if (std.mem.eql(u8, n.name, name)) return n.label;
        return null;
    }

    /// The Port with that name (and direction, for an ALSA Port, whose name
    /// is the same both ways); the last one if several share it. As in the
    /// script, a PipeWire Port's direction is not checked.
    pub fn port(g: Graph, name: []const u8, direction: Direction) ?NamedPort {
        var found: ?NamedPort = null;
        for (g.ports) |p| {
            if ((p.alsa == null or p.direction == direction) and std.mem.eql(u8, p.name, name)) found = p;
        }
        return found;
    }

    /// The channel position of the PipeWire Port `id`; empty if it has none.
    pub fn channel(g: Graph, id: u32) []const u8 {
        for (g.ports) |p| if (p.alsa == null and p.pw == id) return p.channel;
        return "";
    }

    /// The Connection between two Endpoints, if there is one.
    pub fn connection(g: Graph, from: usize, to: usize) ?Connection {
        for (g.connections) |c| if (c.from == from and c.to == to) return c;
        return null;
    }

    /// Whether a Device is in the graph, by its id in profiles:
    /// `pw:<node.name>` or `alsa:<client name>`.
    pub fn hasDevice(g: Graph, id: []const u8) bool {
        if (std.mem.cutPrefix(u8, id, "pw:")) |name| return g.nodeLabel(name) != null;
        for (g.ports) |p| {
            const rest = std.mem.cutPrefix(u8, p.name, id) orelse continue;
            if (p.alsa != null and rest.len > 0 and rest[0] == ':') return true;
        }
        return false;
    }

    /// Every Link as a `FROM|TO` line, sorted bytewise and without duplicates.
    pub fn snapshot(g: Graph, arena: Allocator) Allocator.Error![]const []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        for (g.connections) |c| {
            for (c.links) |l| try lines.append(arena, try std.fmt.allocPrint(arena, "{s}|{s}", .{ l.from_name, l.to_name }));
        }
        std.mem.sort([]const u8, lines.items, {}, lessThan);
        var n: usize = 0;
        for (lines.items) |line| {
            if (n > 0 and std.mem.eql(u8, lines.items[n - 1], line)) continue;
            lines.items[n] = line;
            n += 1;
        }
        return lines.items[0..n];
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "snapshot is sorted and unique across Connections" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const g: Graph = .{
        .endpoints = &.{},
        .connections = &.{
            .{ .from = 0, .to = 1, .links = &.{
                .{ .ends = .{ .pw = .{ 3, 4 } }, .from_name = "pw:b:out_FR", .to_name = "pw:c:in_FR" },
                .{ .ends = .{ .pw = .{ 2, 5 } }, .from_name = "pw:b:out_FL", .to_name = "pw:c:in_FL" },
            } },
            .{ .from = 2, .to = 1, .links = &.{
                .{ .ends = .{ .pw = .{ 9, 4 } }, .from_name = "pw:a:out", .to_name = "pw:c:in_FR" },
                .{ .ends = .{ .pw = .{ 3, 4 } }, .from_name = "pw:b:out_FR", .to_name = "pw:c:in_FR" },
            } },
        },
    };
    const snap = try g.snapshot(arena);
    try std.testing.expectEqual(3, snap.len);
    try std.testing.expectEqualStrings("pw:a:out|pw:c:in_FR", snap[0]);
    try std.testing.expectEqualStrings("pw:b:out_FL|pw:c:in_FL", snap[1]);
    try std.testing.expectEqualStrings("pw:b:out_FR|pw:c:in_FR", snap[2]);
}

test "empty graph has an empty snapshot" {
    const g: Graph = .{ .endpoints = &.{}, .connections = &.{} };
    try std.testing.expectEqual(0, (try g.snapshot(std.testing.allocator)).len);
}

test "ALSA addresses" {
    const a = Addr.parse("128:3").?;
    try std.testing.expectEqual(Addr{ .client = 128, .port = 3 }, a);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("128:3", try std.fmt.bufPrint(&buf, "{f}", .{a}));
    for ([_][]const u8{ "", "128", "128:", ":0", "+1:0", "1:-0", "1:0:2", "70000:0", "a:b" }) |s| {
        try std.testing.expectEqual(null, Addr.parse(s));
    }
}
