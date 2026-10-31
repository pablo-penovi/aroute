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

pub const Endpoint = struct {
    /// Display name, with aliases applied once `Graph.applyAliases` has run.
    label: []const u8,
    kind: Kind,
    direction: Direction,
    backend: Backend,
    /// PipeWire port ids, in port order.
    ports: []const u32,
    /// Kept so existing Links to it can be shown and undone, but never offered in a column.
    hidden: bool = false,
};

/// One Port-to-Port wire.
pub const Link = struct {
    out_port: u32,
    in_port: u32,
    /// Port names as stored in profiles: `pw:<node.name>:<port.name>`.
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

pub const Graph = struct {
    endpoints: []Endpoint,
    /// In the order their first Link was found.
    connections: []const Connection,

    pub fn applyAliases(g: *Graph, arena: Allocator, aliases: Aliases) Allocator.Error!void {
        for (g.endpoints) |*ep| ep.label = try aliases.apply(arena, ep.label);
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
                .{ .out_port = 3, .in_port = 4, .from_name = "pw:b:out_FR", .to_name = "pw:c:in_FR" },
                .{ .out_port = 2, .in_port = 5, .from_name = "pw:b:out_FL", .to_name = "pw:c:in_FL" },
            } },
            .{ .from = 2, .to = 1, .links = &.{
                .{ .out_port = 9, .in_port = 4, .from_name = "pw:a:out", .to_name = "pw:c:in_FR" },
                .{ .out_port = 3, .in_port = 4, .from_name = "pw:b:out_FR", .to_name = "pw:c:in_FR" },
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
