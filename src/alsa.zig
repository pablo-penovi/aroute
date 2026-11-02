//! Turns the sequencer's listing into ALSA MIDI Endpoints, one per Port and
//! direction, and the Links between them, as the script's `scan_alsa` and
//! `scan_alsa_links` do with `aconnect`'s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const Addr = graph.Addr;
const Direction = graph.Direction;
const seq = @import("seq.zig");

/// A Link between two of `Scan.endpoints`.
pub const ScannedLink = struct {
    from: usize,
    to: usize,
    link: graph.Link,
};

pub const Scan = struct {
    /// Sources first, then Destinations, each in the listing's order.
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

/// Everything returned is allocated in `arena`, and may point into `listing`.
/// `show_all` keeps `Midi Through` clients and `*Sync` ports visible.
pub fn parse(arena: Allocator, listing: seq.Listing, show_all: bool) Allocator.Error!Scan {
    var scan: Scan = .{};
    var endpoints: std.ArrayList(graph.Endpoint) = .empty;
    // The client name of each Endpoint, for labelling.
    var clients: std.ArrayList([]const u8) = .empty;

    for ([_]Direction{ .from, .to }) |direction| {
        for (listing.ports) |p| {
            if (!listed(p, direction)) continue;
            const client = listing.clientName(p.addr.client) orelse continue;
            if (p.addr.client == 0 or std.mem.startsWith(u8, client, "PipeWire-")) continue;
            // `aconnect` padded names with spaces, which profiles never kept.
            const name = std.mem.trimEnd(u8, p.name, " ");
            try scan.names.put(arena, p.addr, try std.fmt.allocPrint(arena, "{s}:{s}", .{ client, name }));
            try endpoints.append(arena, .{
                .label = name,
                .kind = .midi,
                .direction = direction,
                .ports = .{ .alsa = .{ .addr = p.addr } },
                .hidden = !show_all and (std.mem.eql(u8, client, "Midi Through") or std.mem.endsWith(u8, name, "Sync")),
            });
            try clients.append(arena, client);
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

    var links: std.ArrayList(ScannedLink) = .empty;
    for (listing.subscriptions) |sub| {
        const from = scan.find(.from, sub.from) orelse continue;
        const to = scan.find(.to, sub.to) orelse continue;
        try links.append(arena, .{ .from = from, .to = to, .link = .{
            .ends = .{ .alsa = .{ sub.from, sub.to } },
            .from_name = try std.fmt.allocPrint(arena, "alsa:{s}", .{scan.name(sub.from)}),
            .to_name = try std.fmt.allocPrint(arena, "alsa:{s}", .{scan.name(sub.to)}),
        } });
    }
    scan.links = links.items;
    return scan;
}

/// Sources are what `aconnect -i` listed, Destinations what `aconnect -o`
/// listed: Ports others may subscribe that way, unless only their own client
/// may route them.
fn listed(p: seq.Port, direction: Direction) bool {
    if (p.caps.no_export) return false;
    return switch (direction) {
        .from => p.caps.read and p.caps.subs_read and p.direction.allows(.input),
        .to => p.caps.write and p.caps.subs_write and p.direction.allows(.output),
    };
}

const testing = std.testing;

const fixture = @import("testdata/seq-listing.zig").listing;

fn expectEndpoint(ep: graph.Endpoint, label: []const u8, direction: Direction, addr: []const u8, hidden: bool) !void {
    try testing.expectEqualStrings(label, ep.label);
    try testing.expectEqual(direction, ep.direction);
    try testing.expectEqual(graph.Kind.midi, ep.kind);
    try testing.expectEqual(Addr.parse(addr).?, ep.ports.alsa.addr);
    try testing.expectEqual(null, ep.ports.alsa.bridge);
    try testing.expectEqual(hidden, ep.hidden);
}

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

test "fixture: Links from the subscriptions, between listed Ports only" {
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

const rw: seq.Caps = .{ .read = true, .write = true, .subs_read = true, .subs_write = true };

test "a single-port client is labelled per direction, hidden ports not counted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), .{
        .clients = &.{ .{ .id = 20, .name = "Pad" }, .{ .id = 21, .name = "Midi Through" } },
        .ports = &.{
            .{ .addr = .{ .client = 20, .port = 0 }, .name = "Pad MIDI 1", .caps = .{ .read = true, .subs_read = true } },
            .{ .addr = .{ .client = 20, .port = 1 }, .name = "Pad MIDI 2", .caps = rw },
            .{ .addr = .{ .client = 21, .port = 0 }, .name = "Midi Through Port-0", .caps = .{ .read = true, .subs_read = true } },
            .{ .addr = .{ .client = 21, .port = 1 }, .name = "Midi Through Port-1", .caps = .{ .read = true, .subs_read = true } },
        },
    }, false);
    try testing.expectEqual(5, s.endpoints.len);
    try expectEndpoint(s.endpoints[0], "Pad MIDI 1", .from, "20:0", false);
    try expectEndpoint(s.endpoints[1], "Pad MIDI 2", .from, "20:1", false);
    // No visible Port at all: also by client name.
    try expectEndpoint(s.endpoints[2], "Midi Through", .from, "21:0", true);
    try expectEndpoint(s.endpoints[3], "Midi Through", .from, "21:1", true);
    try expectEndpoint(s.endpoints[4], "Pad", .to, "20:1", false);
}

test "Sources and Destinations are what aconnect -i and -o listed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), .{
        .clients = &.{.{ .id = 24, .name = "Synth" }},
        .ports = &.{
            .{ .addr = .{ .client = 24, .port = 0 }, .name = "both", .caps = rw },
            .{ .addr = .{ .client = 24, .port = 1 }, .name = "private", .caps = .{ .read = true, .write = true, .subs_read = true, .subs_write = true, .no_export = true } },
            .{ .addr = .{ .client = 24, .port = 2 }, .name = "write only", .caps = .{ .write = true, .subs_write = true } },
            // Readable and writable, but only by its own client's subscriptions.
            .{ .addr = .{ .client = 24, .port = 3 }, .name = "unsubscribable", .caps = .{ .read = true, .write = true } },
            .{ .addr = .{ .client = 24, .port = 4 }, .name = "in", .caps = rw, .direction = .input },
            .{ .addr = .{ .client = 24, .port = 5 }, .name = "out", .caps = rw, .direction = .output },
            .{ .addr = .{ .client = 24, .port = 6 }, .name = "duplex", .caps = rw, .direction = .bidirection },
        },
    }, false);
    const want = [_]struct { []const u8, Direction, []const u8 }{
        .{ "both", .from, "24:0" },
        .{ "in", .from, "24:4" },
        .{ "duplex", .from, "24:6" },
        .{ "both", .to, "24:0" },
        .{ "write only", .to, "24:2" },
        .{ "out", .to, "24:5" },
        .{ "duplex", .to, "24:6" },
    };
    try testing.expectEqual(want.len, s.endpoints.len);
    for (want, s.endpoints) |w, ep| try expectEndpoint(ep, w[0], w[1], w[2], false);
}

test "trailing spaces are trimmed from Port names, System and unknown clients skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try parse(arena_state.allocator(), .{
        .clients = &.{ .{ .id = 0, .name = "System" }, .{ .id = 24, .name = "Synth " } },
        .ports = &.{
            .{ .addr = .{ .client = 0, .port = 0 }, .name = "Timer", .caps = rw },
            .{ .addr = .{ .client = 24, .port = 0 }, .name = " Synth Out  ", .caps = rw },
            .{ .addr = .{ .client = 24, .port = 1 }, .name = "Synth In", .caps = rw },
            // A client that isn't listed.
            .{ .addr = .{ .client = 25, .port = 0 }, .name = "orphan", .caps = rw },
        },
        .subscriptions = &.{
            .{ .from = .{ .client = 24, .port = 0 }, .to = .{ .client = 24, .port = 1 } },
            .{ .from = .{ .client = 0, .port = 0 }, .to = .{ .client = 24, .port = 1 } },
            .{ .from = .{ .client = 24, .port = 0 }, .to = .{ .client = 25, .port = 0 } },
        },
    }, false);
    try testing.expectEqual(4, s.endpoints.len);
    try expectEndpoint(s.endpoints[0], " Synth Out", .from, "24:0", false);
    try testing.expectEqualStrings("Synth : Synth Out", s.name(.{ .client = 24, .port = 0 }));
    try testing.expectEqual(1, s.links.len);
    try testing.expectEqualStrings("alsa:Synth : Synth Out", s.links[0].link.from_name);
    try testing.expectEqualStrings("alsa:Synth :Synth In", s.links[0].link.to_name);
}

test "no listing, no Endpoints" {
    const s = try parse(testing.allocator, .none, false);
    try testing.expectEqual(0, s.endpoints.len);
    try testing.expectEqual(0, s.links.len);
}
