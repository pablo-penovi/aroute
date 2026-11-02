//! Turns `pw-dump` JSON, together with the ALSA scan, into the whole graph, as
//! the script's `scan` does: the ALSA MIDI Endpoints first, then one Endpoint
//! per PipeWire node / direction / Kind / port-name stem, then hidden
//! Endpoints for every other port (raw hardware, monitors), and one Connection
//! per Source/Destination pair with Links. Split devices stand for the
//! hardware Ports behind them. Midi-Bridge ports stand for the ALSA Port they
//! bridge, so PipeWire-only MIDI (e.g. BLE MIDI) can be wired to ALSA MIDI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const graph = @import("graph.zig");
const alsa = @import("alsa.zig");
const Direction = graph.Direction;
const Kind = graph.Kind;

pub const ParseError = error{InvalidDump} || Allocator.Error;

const Node = struct {
    name: []const u8 = "",
    label: []const u8 = "?",
    class: []const u8 = "",
};

const Port = struct {
    id: u32,
    node: ?i64,
    direction: Direction,
    kind: Kind,
    /// `port.id`: the port's position within its node and direction.
    index: i64,
    name: []const u8,
    monitor: bool,
    /// The ALSA Port it stands for, on a Midi-Bridge port.
    bridge: ?Bridged = null,
};

const Bridged = struct {
    addr: graph.Addr,
    direction: Direction,
};

const Group = struct {
    node: ?i64,
    direction: Direction,
    kind: Kind,
    stem: []const u8,
    hidden: bool,
    ports: std.ArrayList(u32) = .empty,
};

/// The PipeWire Endpoints being built, in the order they were found.
const Groups = struct {
    items: std.ArrayList(Group) = .empty,

    /// Adds `port` to the group of its node / direction / Kind and `port_stem`,
    /// started if need be, and returns that group's index.
    fn add(gs: *Groups, arena: Allocator, port: *const Port, port_stem: []const u8, hidden: bool) Allocator.Error!usize {
        const i = for (gs.items.items, 0..) |g, i| {
            if (g.hidden == hidden and g.node == port.node and g.direction == port.direction and
                g.kind == port.kind and std.mem.eql(u8, g.stem, port_stem)) break i;
        } else blk: {
            try gs.items.append(arena, .{
                .node = port.node,
                .direction = port.direction,
                .kind = port.kind,
                .stem = port_stem,
                .hidden = hidden,
            });
            break :blk gs.items.items.len - 1;
        };
        try gs.items.items[i].ports.append(arena, port.id);
        return i;
    }

    /// How many visible groups a node has in one direction and Kind.
    fn count(gs: Groups, node: ?i64, direction: Direction, kind: Kind) usize {
        var n: usize = 0;
        for (gs.items.items) |g| {
            if (!g.hidden and g.node == node and g.direction == direction and g.kind == kind) n += 1;
        }
        return n;
    }

    /// The node's visible group in one direction and Kind, if it has exactly one.
    fn only(gs: Groups, node: ?i64, direction: Direction, kind: Kind) ?usize {
        var found: ?usize = null;
        for (gs.items.items, 0..) |g, i| {
            if (g.hidden or g.node != node or g.direction != direction or g.kind != kind) continue;
            if (found != null) return null;
            found = i;
        }
        return found;
    }
};

const PendingConnection = struct {
    from: usize,
    to: usize,
    links: std.ArrayList(graph.Link) = .empty,
};

/// Everything returned is allocated in `arena`, and may point into `dump` and `scan`.
pub fn parse(arena: Allocator, dump: []const u8, scan: alsa.Scan) ParseError!graph.Graph {
    // pw-dump repeats keys in some params (e.g. a stream's `Tag` has `info` twice).
    const options: json.ParseOptions = .{ .duplicate_field_behavior = .use_last };
    const root = json.parseFromSliceLeaky(json.Value, arena, dump, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDump,
    };
    if (root != .array) return error.InvalidDump;

    var nodes: std.AutoHashMapUnmanaged(i64, Node) = .empty;
    var ports: std.ArrayList(Port) = .empty;
    var links: std.ArrayList([2]u32) = .empty;

    for (root.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = integer(obj.get("id")) orelse continue;
        const info = object(obj.get("info")) orelse continue;
        const type_name = string(obj.get("type")) orelse continue;

        if (std.mem.eql(u8, type_name, "PipeWire:Interface:Node")) {
            try nodes.put(arena, id, readNode(object(info.get("props"))));
        } else if (std.mem.eql(u8, type_name, "PipeWire:Interface:Port")) {
            if (try readPort(id, info)) |port| try ports.append(arena, port);
        } else if (std.mem.eql(u8, type_name, "PipeWire:Interface:Link")) {
            const out = portId(integer(info.get("output-port-id"))) orelse continue;
            const in = portId(integer(info.get("input-port-id"))) orelse continue;
            try links.append(arena, .{ out, in });
        }
    }

    std.mem.sort(Port, ports.items, {}, portLessThan);

    var endpoints: std.ArrayList(graph.Endpoint) = .empty;
    try endpoints.appendSlice(arena, scan.endpoints);

    var port_endpoint: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    var port_by_id: std.AutoHashMapUnmanaged(u32, *const Port) = .empty;
    // As the script's NODE_BYNAME: nodes with ports only, the last one wins.
    var node_by_name: std.StringHashMapUnmanaged(?i64) = .empty;
    for (ports.items) |*port| {
        try port_by_id.put(arena, port.id, port);
        try node_by_name.put(arena, nodeOf(nodes, port.node).name, port.node);
    }

    // Pass 1: one visible Endpoint per node / direction / Kind / stem, in port
    // order, after the ALSA ones.
    var groups: Groups = .{};
    for (ports.items) |*port| {
        if (port.bridge) |b| {
            const ep = scan.find(b.direction, b.addr) orelse continue;
            endpoints.items[ep].ports.alsa.bridge = port.id;
            try port_endpoint.put(arena, port.id, ep);
            continue;
        }
        const node = nodeOf(nodes, port.node);
        if (isSplit(node) or std.mem.find(u8, node.class, "Internal") != null) continue;
        // A virtual source (a null sink, e.g. "Renoise Virtual") only outputs
        // through its monitor ports, so those stay visible.
        if (port.monitor and !std.mem.eql(u8, node.class, "Audio/Source/Virtual")) continue;
        const g = try groups.add(arena, port, if (port.kind == .midi) port.name else stem(port.name), false);
        try port_endpoint.put(arena, port.id, scan.endpoints.len + g);
    }
    const visible = groups.items.items.len;

    // UCM split devices (e.g. "MiniFuse 1 Main Output L/R") are loopbacks, the
    // `<node>.split` stream, onto a raw multichannel node. Sources read
    // straight from the hardware Ports behind them (no software gain on
    // recordings); sinks keep their own Ports so the system volume applies.
    // Either way, Links to those hardware Ports show under the split Endpoint.
    var claimed: std.DynamicBitSetUnmanaged = try .initEmpty(arena, visible);
    for (ports.items) |port| {
        const name = nodeOf(nodes, port.node).name;
        const device = std.mem.cutSuffix(u8, name, ".split") orelse continue;
        if (port.monitor) continue;
        const v = node_by_name.get(device) orelse continue;
        const hw_direction: Direction = if (port.direction == .from) .to else .from;
        const g = groups.only(v, hw_direction, .audio) orelse continue;
        for (links.items) |link| {
            const hw = if (port.direction == .from)
                (if (link[0] == port.id) link[1] else continue)
            else
                (if (link[1] == port.id) link[0] else continue);
            if (!port_by_id.contains(hw)) continue;
            if (hw_direction == .from) {
                if (!claimed.isSet(g)) {
                    groups.items.items[g].ports.clearRetainingCapacity();
                    claimed.set(g);
                }
                try groups.items.items[g].ports.append(arena, hw);
            }
            try port_endpoint.put(arena, hw, scan.endpoints.len + g);
        }
    }

    // Pass 2: every other port (raw hardware, monitors) in a hidden Endpoint,
    // so existing Links to it still show as Connections and can be undone.
    for (ports.items) |*port| {
        if (port_endpoint.contains(port.id) or port.bridge != null) continue;
        if (isSplit(nodeOf(nodes, port.node))) continue;
        const port_stem = if (port.monitor) "monitor" else if (port.kind == .midi) port.name else stem(port.name);
        const g = try groups.add(arena, port, port_stem, true);
        try port_endpoint.put(arena, port.id, scan.endpoints.len + g);
    }

    for (groups.items.items, try endpoints.addManyAsSlice(arena, groups.items.items.len)) |g, *ep| {
        const label = nodeOf(nodes, g.node).label;
        const siblings = if (g.hidden) 0 else groups.count(g.node, g.direction, g.kind);
        ep.* = .{
            .label = if (g.hidden or siblings > 1) try std.fmt.allocPrint(arena, "{s} · {s}", .{ label, g.stem }) else label,
            .kind = g.kind,
            .direction = g.direction,
            .ports = .{ .pw = g.ports.items },
            .hidden = g.hidden,
        };
    }

    // PipeWire Links first, then ALSA ones; ALSA Endpoint indexes are the same in both.
    var pending: std.ArrayList(PendingConnection) = .empty;
    for (links.items) |link| {
        // Links into a split device's loopback are shown through its hardware Ports.
        if (isSplitPort(nodes, port_by_id, link[0]) or isSplitPort(nodes, port_by_id, link[1])) continue;
        const from = port_endpoint.get(link[0]) orelse continue;
        const to = port_endpoint.get(link[1]) orelse continue;
        try addLink(arena, &pending, from, to, .{
            .ends = .{ .pw = link },
            .from_name = try portName(arena, nodes, scan, port_by_id.get(link[0]).?),
            .to_name = try portName(arena, nodes, scan, port_by_id.get(link[1]).?),
        });
    }
    for (scan.links) |l| try addLink(arena, &pending, l.from, l.to, l.link);

    const connections = try arena.alloc(graph.Connection, pending.items.len);
    for (pending.items, connections) |p, *c| c.* = .{ .from = p.from, .to = p.to, .links = p.links.items };

    const named = try arena.alloc(graph.Node, node_by_name.count());
    var it = node_by_name.iterator();
    for (named) |*n| {
        const e = it.next().?;
        n.* = .{ .name = e.key_ptr.*, .label = nodeOf(nodes, e.value_ptr.*).label };
    }

    var named_ports: std.ArrayList(graph.NamedPort) = .empty;
    for (endpoints.items[0..scan.endpoints.len]) |ep| {
        const a = ep.ports.alsa;
        try named_ports.append(arena, .{
            .name = try std.fmt.allocPrint(arena, "alsa:{s}", .{scan.name(a.addr)}),
            .direction = ep.direction,
            .kind = ep.kind,
            .pw = a.bridge,
            .alsa = a.addr,
        });
    }
    for (ports.items) |*port| {
        if (port.bridge != null) continue;
        try named_ports.append(arena, .{
            .name = try portName(arena, nodes, scan, port),
            .direction = port.direction,
            .kind = port.kind,
            .pw = port.id,
        });
    }

    return .{ .endpoints = endpoints.items, .connections = connections, .nodes = named, .ports = named_ports.items };
}

fn addLink(arena: Allocator, pending: *std.ArrayList(PendingConnection), from: usize, to: usize, link: graph.Link) Allocator.Error!void {
    const c = for (pending.items, 0..) |c, i| {
        if (c.from == from and c.to == to) break i;
    } else blk: {
        try pending.append(arena, .{ .from = from, .to = to });
        break :blk pending.items.len - 1;
    };
    try pending.items[c].links.append(arena, link);
}

/// A port name minus its channel suffix: `output_01_left` → `output_01`,
/// `capture_FL` → `capture`, `input_3` → `input`.
pub fn stem(name: []const u8) []const u8 {
    const sep = std.mem.findLastAny(u8, name, "_ -") orelse return name;
    const suffix = name[sep + 1 ..];
    const end = std.mem.trimEnd(u8, name[0..sep], "_ -").len;
    if (end == 0 or !isChannelSuffix(suffix)) return name;
    return name[0..end];
}

fn isChannelSuffix(s: []const u8) bool {
    const names = [_][]const u8{ "left", "right", "l", "r", "fl", "fr", "mono" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n)) return true;
    const digits = if (std.ascii.startsWithIgnoreCase(s, "aux")) s[3..] else s;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn readNode(props: ?json.ObjectMap) Node {
    const p = props orelse return .{};
    const class = string(p.get("media.class")) orelse "";
    const label = if (std.mem.startsWith(u8, class, "Stream/"))
        first(p, &.{ "application.name", "node.description", "media.name", "node.name" })
    else
        first(p, &.{ "node.description", "node.nick", "application.name", "node.name" });
    return .{
        .name = string(p.get("node.name")) orelse "",
        .label = label orelse "?",
        .class = class,
    };
}

fn readPort(id: i64, info: json.ObjectMap) Allocator.Error!?Port {
    const props = object(info.get("props")) orelse return null;
    const format = string(props.get("format.dsp")) orelse return null;
    const kind: Kind = if (std.mem.find(u8, format, "audio") != null)
        .audio
    else if (std.mem.find(u8, format, "midi") != null or std.mem.find(u8, format, "UMP") != null)
        .midi
    else
        return null;
    const direction = string(info.get("direction")) orelse "";
    const monitor = props.get("port.monitor");
    return .{
        .id = portId(id) orelse return null,
        .node = integer(props.get("node.id")),
        .direction = if (std.mem.eql(u8, direction, "output")) .from else .to,
        .kind = kind,
        .bridge = bridged(string(props.get("object.path")) orelse ""),
        .index = integer(props.get("port.id")) orelse 0,
        .name = string(props.get("port.name")) orelse "",
        .monitor = if (monitor) |m| switch (m) {
            .bool => |b| b,
            .string => |s| std.mem.eql(u8, s, "true"),
            else => false,
        } else false,
    };
}

/// A Midi-Bridge port's `object.path`, `alsa:seq:<card>:client_<N>:capture_<M>`
/// or `…:playback_<M>`: the ALSA Port `N:M` it reads from or writes to.
fn bridged(path: []const u8) ?Bridged {
    var parts = std.mem.splitScalar(u8, std.mem.cutPrefix(u8, path, "alsa:seq:") orelse return null, ':');
    _ = parts.next().?; // the card
    const client = std.mem.cutPrefix(u8, parts.next() orelse return null, "client_") orelse return null;
    const port = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const capture = std.mem.cutPrefix(u8, port, "capture_");
    const index = capture orelse std.mem.cutPrefix(u8, port, "playback_") orelse return null;
    return .{
        .addr = .{ .client = graph.number(client) orelse return null, .port = graph.number(index) orelse return null },
        .direction = if (capture != null) .from else .to,
    };
}

/// Same order as the script: node id (missing first), Sources first, then `port.id`.
fn portLessThan(_: void, a: Port, b: Port) bool {
    if (a.node != b.node) {
        const an = a.node orelse return true;
        const bn = b.node orelse return false;
        return an < bn;
    }
    if (a.direction != b.direction) return a.direction == .from;
    return a.index < b.index;
}

fn portName(arena: Allocator, nodes: std.AutoHashMapUnmanaged(i64, Node), scan: alsa.Scan, port: *const Port) Allocator.Error![]const u8 {
    if (port.bridge) |b| return std.fmt.allocPrint(arena, "alsa:{s}", .{scan.name(b.addr)});
    return std.fmt.allocPrint(arena, "pw:{s}:{s}", .{ nodeOf(nodes, port.node).name, port.name });
}

fn nodeOf(nodes: std.AutoHashMapUnmanaged(i64, Node), id: ?i64) Node {
    return nodes.get(id orelse return .{}) orelse .{};
}

/// The loopback stream of a UCM split device: `<node.name>.split`.
fn isSplit(node: Node) bool {
    return std.mem.endsWith(u8, node.name, ".split");
}

fn isSplitPort(nodes: std.AutoHashMapUnmanaged(i64, Node), port_by_id: std.AutoHashMapUnmanaged(u32, *const Port), id: u32) bool {
    const port = port_by_id.get(id) orelse return false;
    return isSplit(nodeOf(nodes, port.node));
}

fn first(props: json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| if (string(props.get(k))) |s| return s;
    return null;
}

fn string(v: ?json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn integer(v: ?json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

fn object(v: ?json.Value) ?json.ObjectMap {
    return switch (v orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn portId(i: ?i64) ?u32 {
    return std.math.cast(u32, i orelse return null);
}

const testing = std.testing;

test "stem drops the channel suffix" {
    const cases = [_][2][]const u8{
        .{ "output_01_left", "output_01" },
        .{ "output_01_right", "output_01" },
        .{ "output_02_L", "output_02" },
        .{ "capture_FL", "capture" },
        .{ "playback_FR", "playback" },
        .{ "capture_MONO", "capture" },
        .{ "input_1", "input" },
        .{ "input_12", "input" },
        .{ "playback_AUX0", "playback" },
        .{ "Out 2", "Out" },
        .{ "out-r", "out" },
        .{ "send__ left", "send" },
        // Not a channel suffix, or nothing in front of it: unchanged.
        .{ "mono", "mono" },
        .{ "_left", "_left" },
        .{ "output_", "output_" },
        .{ "output_aux", "output_aux" },
        .{ "output_center", "output_center" },
        .{ "midi_out", "midi_out" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], stem(c[0]));
}

/// A hand-written dump: `id`s are what the tests refer to.
fn testNode(comptime id: u32, comptime props: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"id":{d},"type":"PipeWire:Interface:Node","info":{{"props":{{{s}}}}}}},
    , .{ id, props });
}

fn testPort(comptime id: u32, comptime node: u32, comptime dir: []const u8, comptime index: u32, comptime name: []const u8) []const u8 {
    return testPortProps(id, node, dir, index, name, "\"format.dsp\":\"32 bit float mono audio\"");
}

fn testMidiPort(comptime id: u32, comptime node: u32, comptime dir: []const u8, comptime index: u32, comptime name: []const u8, comptime path: []const u8) []const u8 {
    return testPortProps(id, node, dir, index, name, "\"format.dsp\":\"8 bit raw midi\",\"object.path\":\"" ++ path ++ "\"");
}

fn testPortProps(comptime id: u32, comptime node: u32, comptime dir: []const u8, comptime index: u32, comptime name: []const u8, comptime props: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"id":{d},"type":"PipeWire:Interface:Port","info":{{"direction":"{s}","props":{{"node.id":{d},"port.id":{d},"port.name":"{s}",{s}}}}}}},
    , .{ id, dir, node, index, name, props });
}

fn testLink(comptime id: u32, comptime out: u32, comptime in: u32) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"id":{d},"type":"PipeWire:Interface:Link","info":{{"output-port-id":{d},"input-port-id":{d}}}}},
    , .{ id, out, in });
}

fn expectEndpoint(ep: graph.Endpoint, label: []const u8, direction: Direction, ports: []const u32) !void {
    try expectAudio(ep, label, direction, ports, false);
}

fn expectHidden(ep: graph.Endpoint, label: []const u8, direction: Direction, ports: []const u32) !void {
    try expectAudio(ep, label, direction, ports, true);
}

fn expectAudio(ep: graph.Endpoint, label: []const u8, direction: Direction, ports: []const u32, hidden: bool) !void {
    try testing.expectEqualStrings(label, ep.label);
    try testing.expectEqual(direction, ep.direction);
    try testing.expectEqual(Kind.audio, ep.kind);
    try testing.expectEqual(graph.Backend.pw, ep.backend());
    try testing.expectEqualSlices(u32, ports, ep.ports.pw);
    try testing.expectEqual(hidden, ep.hidden);
}

test "ports are grouped by stem, with the stem in the label when a node has several" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testNode(10, "\"node.name\":\"renoise\",\"node.description\":\"Renoise\",\"media.class\":\"Audio/Sink\"") ++
        // Out of port order on purpose: Endpoints follow node, direction, port.id.
        testPort(104, 10, "output", 3, "output_02_right") ++
        testPort(101, 10, "output", 0, "output_01_left") ++
        testPort(102, 10, "output", 1, "output_01_right") ++
        testPort(103, 10, "output", 2, "output_02_left") ++
        testPort(105, 10, "input", 0, "input_1") ++
        testPort(106, 10, "input", 1, "input_2") ++
        testNode(20, "\"node.name\":\"mic\",\"node.description\":\"Mic\",\"media.class\":\"Audio/Source\"") ++
        testPort(201, 20, "output", 0, "capture_MONO") ++
        \\{"id":1,"type":"PipeWire:Interface:Client","info":{"props":{}}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(4, g.endpoints.len);
    try expectEndpoint(g.endpoints[0], "Renoise · output_01", .from, &.{ 101, 102 });
    try expectEndpoint(g.endpoints[1], "Renoise · output_02", .from, &.{ 103, 104 });
    try expectEndpoint(g.endpoints[2], "Renoise", .to, &.{ 105, 106 });
    try expectEndpoint(g.endpoints[3], "Mic", .from, &.{201});
    try testing.expectEqual(0, g.connections.len);
}

test "labels: application name for streams, description for devices, then fallbacks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"firefox\",\"node.description\":\"Firefox desc\",\"application.name\":\"Firefox\",\"media.class\":\"Stream/Output/Audio\"") ++
        testNode(2, "\"node.name\":\"s2\",\"media.name\":\"Playback\",\"media.class\":\"Stream/Output/Audio\"") ++
        testNode(3, "\"node.name\":\"dev\",\"node.description\":\"Device\",\"application.name\":\"App\",\"media.class\":\"Audio/Sink\"") ++
        testNode(4, "\"node.name\":\"nick\",\"node.nick\":\"Nick\",\"media.class\":\"Audio/Sink\"") ++
        testNode(5, "\"node.name\":\"bare\"") ++
        testNode(6, "") ++
        testPort(11, 1, "output", 0, "output_FL") ++
        testPort(12, 2, "output", 0, "output_FL") ++
        testPort(13, 3, "input", 0, "playback_FL") ++
        testPort(14, 4, "input", 0, "playback_FL") ++
        testPort(15, 5, "input", 0, "playback_FL") ++
        testPort(16, 6, "input", 0, "playback_FL") ++
        testPort(17, 7, "input", 0, "playback_FL") ++
        \\{"id":99,"type":"PipeWire:Interface:Link","info":{}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    const want = [_][]const u8{ "Firefox", "Playback", "Device", "Nick", "bare", "?", "?" };
    try testing.expectEqual(want.len, g.endpoints.len);
    for (want, g.endpoints) |w, ep| try testing.expectEqualStrings(w, ep.label);
}

test "Internal nodes and monitor ports are hidden Endpoints; other formats are not Endpoints" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"hw\",\"node.description\":\"Raw\",\"media.class\":\"Audio/Sink/Internal\"") ++
        testPort(11, 1, "input", 0, "playback_AUX0") ++
        testNode(2, "\"node.name\":\"sink\",\"node.description\":\"Sink\",\"media.class\":\"Audio/Sink\"") ++
        testPort(21, 2, "input", 0, "playback_FL") ++
        \\{"id":22,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":2,"port.id":0,"port.name":"monitor_FL","port.monitor":true,"format.dsp":"32 bit float mono audio"}}},
        \\{"id":23,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":2,"port.id":1,"port.name":"monitor_FR","port.monitor":"true","format.dsp":"32 bit float mono audio"}}},
        \\{"id":24,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":2,"port.id":2,"port.name":"video","format.dsp":"32 bit float RGBA video"}}},
        \\{"id":25,"type":"PipeWire:Interface:Port","info":{"direction":"output","props":{"node.id":2,"port.id":3,"port.name":"none"}}}
    ++ "]";
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(3, g.endpoints.len);
    try expectEndpoint(g.endpoints[0], "Sink", .to, &.{21});
    // Hidden ones after the visible ones, labelled by stem, or "monitor" for monitor ports.
    try expectHidden(g.endpoints[1], "Raw · playback", .to, &.{11});
    try expectHidden(g.endpoints[2], "Sink · monitor", .from, &.{ 22, 23 });
}

test "Links between two Endpoints form one Connection" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testLink(90, 11, 21) ++
        testLink(91, 12, 22) ++
        testLink(92, 31, 21) ++
        // To a port that does not exist: not shown.
        testLink(94, 11, 999) ++
        testNode(1, "\"node.name\":\"pw-play\",\"application.name\":\"mpv\",\"media.class\":\"Stream/Output/Audio\"") ++
        testPort(11, 1, "output", 0, "output_FL") ++
        testPort(12, 1, "output", 1, "output_FR") ++
        testNode(2, "\"node.name\":\"speakers\",\"node.description\":\"Speakers\",\"media.class\":\"Audio/Sink\"") ++
        testPort(21, 2, "input", 0, "playback_FL") ++
        testPort(22, 2, "input", 1, "playback_FR") ++
        testNode(3, "\"node.name\":\"mic\",\"node.description\":\"Mic\",\"media.class\":\"Audio/Source\"") ++
        testPort(31, 3, "output", 0, "capture_MONO") ++
        testNode(4, "\"node.name\":\"unused\",\"node.description\":\"Unused\",\"media.class\":\"Audio/Sink\"") ++
        testPort(41, 4, "input", 0, "playback_MONO") ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const arena = arena_state.allocator();
    const g = try parse(arena, dump, .none);
    try testing.expectEqual(4, g.endpoints.len);
    try testing.expectEqualStrings("mpv", g.endpoints[0].label);
    try testing.expectEqualStrings("Speakers", g.endpoints[1].label);
    try testing.expectEqualStrings("Mic", g.endpoints[2].label);

    try testing.expectEqual(2, g.connections.len);
    const play = g.connections[0];
    try testing.expectEqual(0, play.from);
    try testing.expectEqual(1, play.to);
    try testing.expectEqual(2, play.links.len);
    try testing.expectEqual([2]u32{ 11, 21 }, play.links[0].ends.pw);
    try testing.expectEqualStrings("pw:pw-play:output_FL", play.links[0].from_name);
    try testing.expectEqualStrings("pw:speakers:playback_FL", play.links[0].to_name);
    try testing.expectEqualStrings("pw:pw-play:output_FR", play.links[1].from_name);
    const mic = g.connections[1];
    try testing.expectEqual(2, mic.from);
    try testing.expectEqual(1, mic.to);
    try testing.expectEqual(1, mic.links.len);

    const snap = try g.snapshot(arena);
    try testing.expectEqual(3, snap.len);
    try testing.expectEqualStrings("pw:mic:capture_MONO|pw:speakers:playback_FL", snap[0]);
    try testing.expectEqualStrings("pw:pw-play:output_FL|pw:speakers:playback_FL", snap[1]);
    try testing.expectEqualStrings("pw:pw-play:output_FR|pw:speakers:playback_FR", snap[2]);
}

test "repeated keys, as pw-dump writes them for stream params, are accepted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testPort(11, 1, "output", 0, "output_FL") ++
        \\{"id":1,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"pw-play","application.name":"pw-play","media.class":"Stream/Output/Audio"},
        \\ "params":{"Tag":[{"direction":"Output","info":[1,"media.name","-"],"info":[1,"media.name","-"]}]}}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(1, g.endpoints.len);
    try testing.expectEqualStrings("pw-play", g.endpoints[0].label);
}

test "out of memory at any allocation is reported, not mistaken for a bad dump" {
    const parseInArena = struct {
        fn f(allocator: Allocator, dump: []const u8) !void {
            var arena_state: std.heap.ArenaAllocator = .init(allocator);
            defer arena_state.deinit();
            _ = try parse(arena_state.allocator(), dump, .none);
        }
    }.f;
    try testing.checkAllAllocationFailures(testing.allocator, parseInArena, .{@embedFile("testdata/pw-dump-streams.json")});
}

test "not a pw-dump" {
    try testing.expectError(error.InvalidDump, parse(testing.allocator, "pw-dump: error", .none));
    try testing.expectError(error.InvalidDump, parse(testing.allocator, "{}", .none));
}

test "real machine: idle graph" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const g = try parse(arena_state.allocator(), @embedFile("testdata/pw-dump-idle.json"), .none);
    // Every Link in this dump is between a split device's loopback and its hardware, so none show.
    try testing.expectEqual(0, g.connections.len);
    // Same as the script's --list on this dump.
    const want = [_]struct { []const u8, Direction, []const u32, bool }{
        .{ "USB Video Analog Stereo", .from, &.{ 73, 74 }, false },
        .{ "Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x]", .to, &.{ 78, 77 }, false },
        // The Midi-Bridge's ports have no ALSA scan to map to, so only BLE MIDI shows.
        .{ "BLE MIDI 1", .from, &.{54}, false },
        .{ "BLE MIDI 1", .to, &.{53}, false },
        // Split sinks keep their own Ports.
        .{ "MiniFuse 1 Loopback L/R", .to, &.{ 81, 82 }, false },
        .{ "MiniFuse 1 Main Output L/R", .to, &.{ 87, 88 }, false },
        // Split sources read from the hardware Ports behind them.
        .{ "MiniFuse 1 Loopback L/R", .from, &.{ 110, 111 }, false },
        .{ "MiniFuse 1 Mic/Line/Inst 1 (L)", .from, &.{108}, false },
        .{ "Starship/Matisse HD Audio Controller Digital Stereo (IEC958)", .to, &.{ 112, 113 }, false },
        .{ "Starship/Matisse HD Audio Controller Analog Stereo", .from, &.{ 116, 117 }, false },
        // A null sink: its monitors are its output.
        .{ "Renoise Virtual", .from, &.{ 156, 155 }, false },
        .{ "Renoise Virtual", .to, &.{ 158, 147 }, false },
        .{ "Navi 21/23 HDMI/DP Audio Controller Digital Stereo (HDMI 3) [LS32AG32x] · monitor", .from, &.{ 76, 75 }, true },
        .{ "MiniFuse 1 Loopback L/R · monitor", .from, &.{ 83, 84 }, true },
        .{ "MiniFuse 1 Main Output L/R · monitor", .from, &.{ 89, 90 }, true },
        .{ "MiniFuse 1 0 · monitor", .from, &.{ 104, 105, 106, 107 }, true },
        // The one hardware capture Port no split device reads from.
        .{ "MiniFuse 1 0 · capture", .from, &.{109}, true },
        .{ "Starship/Matisse HD Audio Controller Digital Stereo (IEC958) · monitor", .from, &.{ 114, 115 }, true },
    };
    try testing.expectEqual(want.len, g.endpoints.len);
    for (want, g.endpoints) |w, ep| {
        try testing.expectEqualStrings(w[0], ep.label);
        try testing.expectEqual(w[1], ep.direction);
        try testing.expectEqualSlices(u32, w[2], ep.ports.pw);
        try testing.expectEqual(w[3], ep.hidden);
    }
}

test "split sink: keeps its own Ports, and Links to the hardware behind it show under it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"out\",\"node.description\":\"Main Out\",\"media.class\":\"Audio/Sink\"") ++
        testPort(11, 1, "input", 0, "playback_FL") ++
        testPort(12, 1, "input", 1, "playback_FR") ++
        testNode(2, "\"node.name\":\"out.split\",\"node.description\":\"Split Main Out\",\"media.class\":\"Stream/Output/Audio/Internal\"") ++
        testPort(21, 2, "input", 0, "input_FL") ++
        testPort(22, 2, "output", 0, "output_AUX0") ++
        testPort(23, 2, "output", 1, "output_AUX1") ++
        testNode(3, "\"node.name\":\"hw\",\"node.description\":\"Card\",\"media.class\":\"Audio/Sink/Internal\"") ++
        testPort(31, 3, "input", 0, "playback_AUX0") ++
        testPort(32, 3, "input", 1, "playback_AUX1") ++
        testPort(33, 3, "input", 2, "playback_AUX2") ++
        testNode(4, "\"node.name\":\"pw-play\",\"application.name\":\"play\",\"media.class\":\"Stream/Output/Audio\"") ++
        testPort(41, 4, "output", 0, "output_FL") ++
        testPort(42, 4, "output", 1, "output_FR") ++
        // The split device's own loopback, or anything else to or from it: not shown.
        testLink(90, 22, 31) ++
        testLink(91, 23, 32) ++
        testLink(92, 41, 21) ++
        // Straight to the hardware Ports behind it, and to its own Ports: one Connection.
        testLink(93, 41, 31) ++
        testLink(94, 42, 12) ++
        // To the hardware Port no split device writes to: a hidden Endpoint.
        testLink(95, 41, 33) ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena, dump, .none);
    try testing.expectEqual(3, g.endpoints.len);
    try expectEndpoint(g.endpoints[0], "Main Out", .to, &.{ 11, 12 });
    try expectEndpoint(g.endpoints[1], "play", .from, &.{ 41, 42 });
    try expectHidden(g.endpoints[2], "Card · playback", .to, &.{33});

    try testing.expectEqual(2, g.connections.len);
    try testing.expectEqual(1, g.connections[0].from);
    try testing.expectEqual(0, g.connections[0].to);
    try testing.expectEqual(2, g.connections[0].links.len);
    try testing.expectEqual([2]u32{ 41, 31 }, g.connections[0].links[0].ends.pw);
    try testing.expectEqualStrings("pw:hw:playback_AUX0", g.connections[0].links[0].to_name);
    try testing.expectEqual([2]u32{ 42, 12 }, g.connections[0].links[1].ends.pw);
    try testing.expectEqual(1, g.connections[1].from);
    try testing.expectEqual(2, g.connections[1].to);
}

test "split source: reads from the hardware Ports behind it, whose Links show under it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"in\",\"node.description\":\"Line In\",\"media.class\":\"Audio/Source\"") ++
        testPort(11, 1, "output", 0, "capture_FL") ++
        testPort(12, 1, "output", 1, "capture_FR") ++
        testNode(2, "\"node.name\":\"in.split\",\"node.description\":\"Split Line In\",\"media.class\":\"Stream/Input/Audio/Internal\"") ++
        testPort(21, 2, "input", 0, "input_AUX0") ++
        testPort(22, 2, "input", 1, "input_AUX1") ++
        testPortProps(23, 2, "output", 0, "monitor_AUX0", "\"port.monitor\":true,\"format.dsp\":\"32 bit float mono audio\"") ++
        testNode(3, "\"node.name\":\"hw\",\"node.description\":\"Card\",\"media.class\":\"Audio/Source/Internal\"") ++
        testPort(31, 3, "output", 0, "capture_AUX0") ++
        testPort(32, 3, "output", 1, "capture_AUX1") ++
        testPort(33, 3, "output", 2, "capture_AUX2") ++
        testNode(4, "\"node.name\":\"pw-record\",\"application.name\":\"rec\",\"media.class\":\"Stream/Input/Audio\"") ++
        testPort(41, 4, "input", 0, "input_FL") ++
        testPort(42, 4, "input", 1, "input_FR") ++
        testLink(90, 32, 22) ++
        testLink(91, 31, 21) ++
        testLink(92, 23, 41) ++
        // From the hardware behind it, and from its own Ports: one Connection.
        testLink(93, 31, 41) ++
        testLink(94, 12, 42) ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena, dump, .none);
    try testing.expectEqual(3, g.endpoints.len);
    // In split port order, each one's hardware Ports in Link order.
    try expectEndpoint(g.endpoints[0], "Line In", .from, &.{ 31, 32 });
    try expectEndpoint(g.endpoints[1], "rec", .to, &.{ 41, 42 });
    try expectHidden(g.endpoints[2], "Card · capture", .from, &.{33});

    try testing.expectEqual(1, g.connections.len);
    try testing.expectEqual(0, g.connections[0].from);
    try testing.expectEqual(1, g.connections[0].to);
    try testing.expectEqual(2, g.connections[0].links.len);
    try testing.expectEqualStrings("pw:hw:capture_AUX0", g.connections[0].links[0].from_name);
    try testing.expectEqualStrings("pw:in:capture_FR", g.connections[0].links[1].from_name);
}

test "split device whose node has several Endpoints that way, or none: its hardware stays hidden" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"in\",\"node.description\":\"In\",\"media.class\":\"Audio/Source\"") ++
        testPort(11, 1, "output", 0, "out_1_FL") ++
        testPort(12, 1, "output", 1, "out_2_FL") ++
        testNode(2, "\"node.name\":\"in.split\",\"media.class\":\"Stream/Input/Audio/Internal\"") ++
        testPort(21, 2, "input", 0, "input_AUX0") ++
        testNode(3, "\"node.name\":\"gone.split\",\"media.class\":\"Stream/Input/Audio/Internal\"") ++
        testPort(31, 3, "input", 0, "input_AUX0") ++
        testNode(4, "\"node.name\":\"hw\",\"node.description\":\"Card\",\"media.class\":\"Audio/Source/Internal\"") ++
        testPort(41, 4, "output", 0, "capture_AUX0") ++
        testPort(42, 4, "output", 1, "capture_AUX1") ++
        testLink(90, 41, 21) ++
        testLink(91, 42, 31) ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(3, g.endpoints.len);
    try expectEndpoint(g.endpoints[0], "In · out_1", .from, &.{11});
    try expectEndpoint(g.endpoints[1], "In · out_2", .from, &.{12});
    try expectHidden(g.endpoints[2], "Card · capture", .from, &.{ 41, 42 });
    try testing.expectEqual(0, g.connections.len);
}

test "a virtual source's monitor ports are its output, unlike other nodes' monitors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const monitor = "\"port.monitor\":true,\"format.dsp\":\"32 bit float mono audio\"";
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"renoise_source\",\"node.description\":\"Renoise Virtual\",\"media.class\":\"Audio/Source/Virtual\"") ++
        testPort(11, 1, "input", 0, "input_FL") ++
        testPort(12, 1, "input", 1, "input_FR") ++
        testPortProps(13, 1, "output", 0, "capture_FL", monitor) ++
        testPortProps(14, 1, "output", 1, "capture_FR", monitor) ++
        testNode(2, "\"node.name\":\"sink\",\"node.description\":\"Sink\",\"media.class\":\"Audio/Sink\"") ++
        testPort(21, 2, "input", 0, "playback_FL") ++
        testPortProps(22, 2, "output", 0, "monitor_FL", monitor) ++
        testNode(3, "\"node.name\":\"pw-record\",\"application.name\":\"rec\",\"media.class\":\"Stream/Input/Audio\"") ++
        testPort(31, 3, "input", 0, "input_MONO") ++
        testLink(90, 13, 31) ++
        testLink(91, 22, 31) ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(5, g.endpoints.len);
    try expectEndpoint(g.endpoints[0], "Renoise Virtual", .from, &.{ 13, 14 });
    try expectEndpoint(g.endpoints[1], "Renoise Virtual", .to, &.{ 11, 12 });
    try expectEndpoint(g.endpoints[2], "Sink", .to, &.{21});
    try expectEndpoint(g.endpoints[3], "rec", .to, &.{31});
    try expectHidden(g.endpoints[4], "Sink · monitor", .from, &.{22});
    // A hidden Endpoint's Links still show as a Connection, so they can be undone.
    try testing.expectEqual(2, g.connections.len);
    try testing.expectEqual(0, g.connections[0].from);
    try testing.expectEqual(3, g.connections[0].to);
    try testing.expectEqual(4, g.connections[1].from);
    try testing.expectEqual(3, g.connections[1].to);
}

test "hidden MIDI Endpoints are one per port name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"seq\",\"node.description\":\"Seq\",\"media.class\":\"Midi/Sink/Internal\"") ++
        testMidiPort(11, 1, "input", 0, "in_1", "seq:in_1") ++
        testMidiPort(12, 1, "input", 1, "in_2", "seq:in_2") ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(2, g.endpoints.len);
    try testing.expectEqualStrings("Seq · in_1", g.endpoints[0].label);
    try testing.expectEqualStrings("Seq · in_2", g.endpoints[1].label);
    for (g.endpoints) |ep| {
        try testing.expect(ep.hidden);
        try testing.expectEqual(Kind.midi, ep.kind);
    }
}

test "PipeWire MIDI ports are one Endpoint per port name, raw MIDI or UMP" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const dump = comptime "[" ++
        testNode(1, "\"node.name\":\"synth\",\"node.description\":\"Synth\",\"media.class\":\"Midi/Bridge\"") ++
        // Not grouped by stem, unlike audio.
        testMidiPort(11, 1, "output", 0, "midi_out_1", "synth:out_1") ++
        testMidiPort(12, 1, "output", 1, "midi_out_2", "synth:out_2") ++
        testPortProps(13, 1, "input", 0, "ump_in", "\"format.dsp\":\"32 bit raw UMP\"") ++
        testPort(14, 1, "input", 1, "playback_FL") ++
        testPort(15, 1, "input", 2, "playback_FR") ++
        testLink(90, 11, 13) ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena_state.allocator(), dump, .none);
    try testing.expectEqual(4, g.endpoints.len);
    const want = [_]struct { []const u8, Direction, Kind, []const u32 }{
        .{ "Synth · midi_out_1", .from, .midi, &.{11} },
        .{ "Synth · midi_out_2", .from, .midi, &.{12} },
        .{ "Synth", .to, .midi, &.{13} },
        // Audio and MIDI are told apart when counting a node's Endpoints.
        .{ "Synth", .to, .audio, &.{ 14, 15 } },
    };
    for (want, g.endpoints) |w, ep| {
        try testing.expectEqualStrings(w[0], ep.label);
        try testing.expectEqual(w[1], ep.direction);
        try testing.expectEqual(w[2], ep.kind);
        try testing.expectEqualSlices(u32, w[3], ep.ports.pw);
    }
    try testing.expectEqual(1, g.connections.len);
    try testing.expectEqualStrings("pw:synth:midi_out_1", g.connections[0].links[0].from_name);
    try testing.expectEqualStrings("pw:synth:ump_in", g.connections[0].links[0].to_name);
}

test "Midi-Bridge ports stand for the ALSA Port they bridge" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scan = try alsa.parse(arena, .{
        .sources = "client 20: 'WORLDE' [type=kernel]\n    0 'WORLDE MIDI 1   '\n" ++
            "client 21: 'Pad' [type=kernel]\n    0 'Pad'\n",
        .destinations = "client 20: 'WORLDE' [type=kernel]\n    0 'WORLDE MIDI 1   '\n",
        .connections = "client 21: 'Pad' [type=kernel]\n    0 'Pad'\n\tConnecting To: 20:0\n",
    }, false);
    const dump = comptime "[" ++
        testNode(5, "\"node.name\":\"Midi-Bridge\",\"media.class\":\"Midi/Bridge\"") ++
        testMidiPort(51, 5, "output", 0, "WORLDE: MIDI 1 (capture)", "alsa:seq:default:client_20:capture_0") ++
        testMidiPort(52, 5, "input", 0, "WORLDE: MIDI 1 (playback)", "alsa:seq:default:client_20:playback_0") ++
        testMidiPort(53, 5, "output", 1, "Pad (capture)", "alsa:seq:default:client_21:capture_0") ++
        // Bridges a Port the ALSA scan does not have: neither an Endpoint nor in a Connection.
        testMidiPort(54, 5, "output", 2, "Gone (capture)", "alsa:seq:default:client_99:capture_0") ++
        testNode(6, "\"node.name\":\"bluez_midi.server\",\"node.description\":\"BLE MIDI 1\",\"media.class\":\"Midi/Bridge\"") ++
        testMidiPort(61, 6, "output", 0, "out", "bluez_midi.server:output_0") ++
        testMidiPort(62, 6, "input", 0, "in", "bluez_midi.server:input_0") ++
        testLink(90, 61, 52) ++
        testLink(91, 51, 62) ++
        testLink(92, 54, 62) ++
        // Wired both through PipeWire and with aconnect: one Connection.
        testLink(93, 53, 52) ++
        \\{"id":0,"type":"PipeWire:Interface:Core","info":{}}]
    ;
    const g = try parse(arena, dump, scan);

    try testing.expectEqual(5, g.endpoints.len);
    const want = [_]struct { []const u8, Direction, graph.Backend }{
        .{ "WORLDE", .from, .alsa },
        .{ "Pad", .from, .alsa },
        .{ "WORLDE", .to, .alsa },
        .{ "BLE MIDI 1", .from, .pw },
        .{ "BLE MIDI 1", .to, .pw },
    };
    for (want, g.endpoints) |w, ep| {
        try testing.expectEqualStrings(w[0], ep.label);
        try testing.expectEqual(w[1], ep.direction);
        try testing.expectEqual(Kind.midi, ep.kind);
        try testing.expectEqual(w[2], ep.backend());
    }
    try testing.expectEqual(51, g.endpoints[0].ports.alsa.bridge);
    try testing.expectEqual(53, g.endpoints[1].ports.alsa.bridge);
    try testing.expectEqual(52, g.endpoints[2].ports.alsa.bridge);
    // The ALSA scan itself is left as it was.
    try testing.expectEqual(null, scan.endpoints[0].ports.alsa.bridge);

    try testing.expectEqual(3, g.connections.len);
    const ble_in = g.connections[0];
    try testing.expectEqual(3, ble_in.from);
    try testing.expectEqual(2, ble_in.to);
    try testing.expectEqual([2]u32{ 61, 52 }, ble_in.links[0].ends.pw);
    try testing.expectEqualStrings("pw:bluez_midi.server:out", ble_in.links[0].from_name);
    try testing.expectEqualStrings("alsa:WORLDE:WORLDE MIDI 1", ble_in.links[0].to_name);
    const ble_out = g.connections[1];
    try testing.expectEqual(0, ble_out.from);
    try testing.expectEqual(4, ble_out.to);
    try testing.expectEqualStrings("alsa:WORLDE:WORLDE MIDI 1", ble_out.links[0].from_name);
    try testing.expectEqualStrings("pw:bluez_midi.server:in", ble_out.links[0].to_name);
    const pad = g.connections[2];
    try testing.expectEqual(1, pad.from);
    try testing.expectEqual(2, pad.to);
    try testing.expectEqual(2, pad.links.len);
    try testing.expectEqual([2]u32{ 53, 52 }, pad.links[0].ends.pw);
    try testing.expectEqual(graph.Addr{ .client = 21, .port = 0 }, pad.links[1].ends.alsa[0]);
    // Same Port names either way, so the snapshot has the Link once.
    try testing.expectEqualStrings(pad.links[0].from_name, pad.links[1].from_name);
    try testing.expectEqualStrings(pad.links[0].to_name, pad.links[1].to_name);
    try testing.expectEqual(3, (try g.snapshot(arena)).len);
}

test "Midi-Bridge object paths" {
    const Want = ?struct { u16, u16, Direction };
    const cases = [_]struct { []const u8, Want }{
        .{ "alsa:seq:default:client_14:capture_0", .{ 14, 0, .from } },
        .{ "alsa:seq:default:client_128:playback_3", .{ 128, 3, .to } },
        .{ "alsa:seq::client_1:capture_2", .{ 1, 2, .from } },
        .{ "alsa:seq:default:client_14:capture_", null },
        .{ "alsa:seq:default:client_x:capture_0", null },
        .{ "alsa:seq:default:client_14:monitor_0", null },
        .{ "alsa:seq:default:client_14:capture_0:x", null },
        .{ "alsa:seq:default:client_14", null },
        .{ "alsa:seq:default", null },
        .{ "alsa:pcm:1:hw:1,0:capture", null },
        .{ "bluez_midi.server:output_0", null },
        .{ "", null },
    };
    for (cases) |c| {
        const got = bridged(c[0]);
        if (c[1]) |w| {
            try testing.expectEqual(graph.Addr{ .client = w[0], .port = w[1] }, got.?.addr);
            try testing.expectEqual(w[2], got.?.direction);
        } else try testing.expectEqual(null, got);
    }
}
