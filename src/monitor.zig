//! Keeps the PipeWire graph up to date from what `pw-dump --monitor` streams
//! (ADR 0003): a series of top-level JSON arrays, the first the whole graph,
//! each later one the objects that changed. Updates are partial, so each is
//! merged into the object it updates. Nothing here runs `pw-dump`; see
//! `tools.zig` for that, and `pipewire.zig` for turning the objects into
//! Endpoints and Connections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const graph = @import("graph.zig");

pub const Error = error{
    /// Not what `pw-dump` writes: the graph can't be read from it.
    InvalidDump,
} || Allocator.Error;

/// One PipeWire object, in memory of its own, so it can be freed when it
/// is replaced or removed.
const Object = struct {
    arena: std.heap.ArenaAllocator,
    value: json.Value,
};

/// The objects `pw-dump --monitor` has written so far, folded by `id`.
pub const Fold = struct {
    gpa: Allocator,
    /// By `id`, in the order they appeared, as a one-shot `pw-dump` lists
    /// them: a new object goes last.
    objects: std.AutoArrayHashMapUnmanaged(i64, *Object) = .empty,
    /// The batch being received, from its `[`, until the whole array is in.
    pending: std.ArrayList(u8) = .empty,
    /// How deep in brackets and braces the end of `pending` is; 0 between batches.
    depth: usize = 0,
    in_string: bool = false,
    /// The last byte of `pending` is a backslash in a string.
    escaped: bool = false,
    /// A whole batch has been folded: the first is the whole graph.
    ready: bool = false,

    pub fn init(gpa: Allocator) Fold {
        return .{ .gpa = gpa };
    }

    pub fn deinit(f: *Fold) void {
        for (f.objects.values()) |o| f.destroy(o);
        f.objects.deinit(f.gpa);
        f.pending.deinit(f.gpa);
    }

    /// Back to nothing received, as for a new `pw-dump`.
    pub fn reset(f: *Fold) void {
        const gpa = f.gpa;
        f.deinit();
        f.* = .init(gpa);
    }

    /// Takes the next `bytes` of the stream, cut anywhere, and folds in
    /// every batch they complete. Returns whether any was.
    pub fn feed(f: *Fold, bytes: []const u8) Error!bool {
        var folded = false;
        // Where the part of `bytes` that belongs to a batch starts.
        var start: usize = 0;
        for (bytes, 0..) |c, i| {
            if (f.depth == 0) {
                switch (c) {
                    ' ', '\t', '\r', '\n' => {
                        start = i + 1;
                        continue;
                    },
                    '[' => start = i,
                    else => return error.InvalidDump,
                }
            }
            if (f.in_string) {
                if (f.escaped) {
                    f.escaped = false;
                } else if (c == '\\') {
                    f.escaped = true;
                } else if (c == '"') {
                    f.in_string = false;
                }
                continue;
            }
            switch (c) {
                '"' => f.in_string = true,
                '[', '{' => f.depth += 1,
                ']', '}' => {
                    f.depth -= 1;
                    if (f.depth > 0) continue;
                    try f.pending.appendSlice(f.gpa, bytes[start .. i + 1]);
                    start = i + 1;
                    defer f.pending.clearRetainingCapacity();
                    try f.apply(f.pending.items);
                    folded = true;
                },
                else => {},
            }
        }
        if (f.depth > 0) try f.pending.appendSlice(f.gpa, bytes[start..]);
        return folded;
    }

    /// Folds in one whole batch.
    fn apply(f: *Fold, batch: []const u8) Error!void {
        var parsed: std.heap.ArenaAllocator = .init(f.gpa);
        defer parsed.deinit();
        // pw-dump repeats keys in some params (e.g. a stream's `Tag` has `info` twice).
        const options: json.ParseOptions = .{ .duplicate_field_behavior = .use_last };
        const root = json.parseFromSliceLeaky(json.Value, parsed.allocator(), batch, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidDump,
        };
        if (root != .array) return error.InvalidDump;
        for (root.array.items) |item| {
            if (item != .object) continue;
            const id = switch (item.object.get("id") orelse continue) {
                .integer => |i| i,
                else => continue,
            };
            const info = item.object.get("info");
            if (info != null and info.? == .null) {
                if (f.objects.fetchOrderedRemove(id)) |kv| f.destroy(kv.value);
            } else if (f.objects.get(id)) |old| {
                const merged = try f.create(old.value.object, item.object);
                f.destroy(old);
                f.objects.putAssumeCapacity(id, merged);
            } else {
                try f.objects.ensureUnusedCapacity(f.gpa, 1);
                f.objects.putAssumeCapacity(id, try f.create(null, item.object));
            }
        }
        f.ready = true;
    }

    /// `update` merged into `old` (if any), in memory of its own: each
    /// top-level field `update` has replaces `old`'s, and so does each field
    /// of its `info`; the fields it doesn't have are kept.
    fn create(f: *Fold, old: ?json.ObjectMap, update: json.ObjectMap) Allocator.Error!*Object {
        const o = try f.gpa.create(Object);
        errdefer f.gpa.destroy(o);
        o.arena = .init(f.gpa);
        errdefer o.arena.deinit();
        const a = o.arena.allocator();

        var merged: json.ObjectMap = .empty;
        if (old) |fields| try putAll(a, &merged, fields);
        try putAll(a, &merged, update);
        const old_info = if (old) |fields| fields.get("info") else null;
        const new_info = update.get("info");
        if (old_info != null and old_info.? == .object and new_info != null and new_info.? == .object) {
            var info: json.ObjectMap = .empty;
            try putAll(a, &info, old_info.?.object);
            try putAll(a, &info, new_info.?.object);
            try merged.put(a, "info", .{ .object = info });
        }
        o.value = .{ .object = merged };
        return o;
    }

    fn destroy(f: *Fold, o: *Object) void {
        o.arena.deinit();
        f.gpa.destroy(o);
    }

    /// Every object, in the order a one-shot `pw-dump` lists them. They
    /// belong to the fold, and change or go with the next `feed`.
    pub fn values(f: *const Fold, arena: Allocator) Allocator.Error![]const json.Value {
        const list = try arena.alloc(json.Value, f.objects.count());
        for (f.objects.values(), list) |o, *v| v.* = o.value;
        return list;
    }

    /// Whether the graph shows the change aroute just made: every PipeWire
    /// Link in `made` is there, and every one in `undone` is gone. ALSA
    /// Links don't count: the sequencer is read directly, so it is never behind.
    pub fn settled(f: *const Fold, made: []const graph.Ends, undone: []const graph.Ends) bool {
        for (made) |e| if (e == .pw and !f.hasLink(e.pw)) return false;
        for (undone) |e| if (e == .pw and f.hasLink(e.pw)) return false;
        return true;
    }

    fn hasLink(f: *const Fold, ends: [2]u32) bool {
        for (f.objects.values()) |o| {
            const obj = o.value.object;
            const t = obj.get("type") orelse continue;
            if (t != .string or !std.mem.eql(u8, t.string, "PipeWire:Interface:Link")) continue;
            const info = obj.get("info") orelse continue;
            if (info != .object) continue;
            if (integer(info.object.get("output-port-id")) == ends[0] and integer(info.object.get("input-port-id")) == ends[1]) return true;
        }
        return false;
    }
};

/// Puts a copy of every field of `from` into `to`, in memory `a`.
fn putAll(a: Allocator, to: *json.ObjectMap, from: json.ObjectMap) Allocator.Error!void {
    var it = from.iterator();
    while (it.next()) |e| try to.put(a, try a.dupe(u8, e.key_ptr.*), try clone(a, e.value_ptr.*));
}

/// A copy of `v` in memory `a`.
fn clone(a: Allocator, v: json.Value) Allocator.Error!json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |items| blk: {
            var copy: json.Array = try .initCapacity(a, items.items.len);
            for (items.items) |item| copy.appendAssumeCapacity(try clone(a, item));
            break :blk .{ .array = copy };
        },
        .object => |fields| blk: {
            var copy: json.ObjectMap = .empty;
            try putAll(a, &copy, fields);
            break :blk .{ .object = copy };
        },
    };
}

fn integer(v: ?json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

const testing = std.testing;
const pipewire = @import("pipewire.zig");

const capture = @embedFile("testdata/pw-dump-monitor.json");
/// A one-shot `pw-dump` taken just before the end of `capture`.
const capture_end = @embedFile("testdata/pw-dump-monitor-end.json");

test "real machine: folding a capture builds the same Graph as a one-shot pw-dump at its end" {
    // The capture: two null sinks appear, Links are made with `pw-link` and
    // one is undone, clients come and go, and the first sink is removed.
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    try testing.expect(try fold.feed(capture));
    try testing.expect(fold.ready);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const want = try pipewire.parse(arena, capture_end, .none);
    const got = try pipewire.build(arena, try fold.values(arena), .none);
    try testing.expectEqualDeep(want, got);
    // The second sink is still there, without Links: the first one went with them.
    try testing.expect(std.mem.find(u8, try std.mem.join(arena, "\n", try labels(arena, got)), "AROUTE_B") != null);
    try testing.expect(std.mem.find(u8, try std.mem.join(arena, "\n", try labels(arena, got)), "AROUTE_A") == null);
}

fn labels(arena: Allocator, g: graph.Graph) ![]const []const u8 {
    const out = try arena.alloc([]const u8, g.endpoints.len);
    for (g.endpoints, out) |ep, *o| o.* = ep.label;
    return out;
}

test "real machine: the capture's Links show up, and go, as they are made and undone" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Batch by batch, the most Connections between the two sinks at once.
    var most: usize = 0;
    var rest: []const u8 = capture;
    while (rest.len > 0) {
        const end = std.mem.find(u8, rest, "\n]\n").? + 3;
        _ = try fold.feed(rest[0..end]);
        rest = rest[end..];
        const g = try pipewire.build(arena, try fold.values(arena), .none);
        var links: usize = 0;
        for (g.connections) |c| {
            // From the first sink's monitor ports, a hidden Endpoint.
            if (std.mem.eql(u8, g.endpoints[c.from].label, "AROUTE_A · monitor") and std.mem.eql(u8, g.endpoints[c.to].label, "AROUTE_B")) links += c.links.len;
        }
        most = @max(most, links);
    }
    try testing.expectEqual(2, most);
    // And none at the end.
    try testing.expectEqual(0, links: {
        const g = try pipewire.build(arena, try fold.values(arena), .none);
        break :links g.connections.len;
    });
}

test "feeding a byte at a time folds the same as feeding it whole" {
    var whole: Fold = .init(testing.allocator);
    defer whole.deinit();
    _ = try whole.feed(capture);
    var bytes: Fold = .init(testing.allocator);
    defer bytes.deinit();
    for (0..capture.len) |i| _ = try bytes.feed(capture[i .. i + 1]);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualDeep(try pipewire.build(arena, try whole.values(arena), .none), try pipewire.build(arena, try bytes.values(arena), .none));
    try testing.expectEqual(whole.objects.count(), bytes.objects.count());
    try testing.expectEqualSlices(i64, whole.objects.keys(), bytes.objects.keys());
}

/// The fold's object `id`, written back as JSON.
fn stringify(arena: Allocator, f: *const Fold, id: i64) ![]const u8 {
    return json.Stringify.valueAlloc(arena, f.objects.get(id).?.value, .{});
}

test "a batch counts only once its whole array is in" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    try testing.expect(!try fold.feed("\n[ {\"id\": 1, \"info\": {\"a\": 1}}"));
    try testing.expect(!fold.ready);
    try testing.expectEqual(0, fold.objects.count());
    try testing.expect(try fold.feed(" ]\n[{\"id\": 2, \"info\": {}}]\n[{\"id\": 3"));
    try testing.expect(fold.ready);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, fold.objects.keys());
    try testing.expect(try fold.feed(", \"info\": {}}]"));
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, fold.objects.keys());
    try testing.expect(!try fold.feed("  \n"));
}

test "brackets and braces in strings, escaped quotes included, don't end a batch" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    const batch =
        \\[{"id": 7, "info": {"props": {"node.description": "Out ]] }} [LS32] \"]\" \\", "x": "\\\\]"}}}]
    ;
    // Cut short just before its end: nothing yet.
    try testing.expect(!try fold.feed(batch[0 .. batch.len - 1]));
    try testing.expectEqual(0, fold.objects.count());
    try testing.expect(try fold.feed(batch[batch.len - 1 ..]));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        \\{"id":7,"info":{"props":{"node.description":"Out ]] }} [LS32] \"]\" \\","x":"\\\\]"}}}
    , try stringify(arena_state.allocator(), &fold, 7));
}

test "an update keeps the fields it doesn't carry; info: null removes the object; a new one goes last" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try fold.feed(
        \\[{"id": 1, "type": "PipeWire:Interface:Client", "version": 3, "info": {"props": {"a": "1"}, "state": "idle"}},
        \\ {"id": 2, "type": "PipeWire:Interface:Node", "info": {"props": {"node.name": "x"}}}]
    );
    // As PipeWire 1.6 writes a client changing its props: those only.
    _ = try fold.feed(
        \\[{"id": 1, "version": 4, "info": {"change-mask": ["props"], "props": {"b": "2"}}}]
    );
    try testing.expectEqualStrings(
        \\{"id":1,"type":"PipeWire:Interface:Client","version":4,"info":{"props":{"b":"2"},"state":"idle","change-mask":["props"]}}
    , try stringify(arena, &fold, 1));

    // An update with no `info`, or an `info` that isn't an object, replaces it whole.
    _ = try fold.feed(
        \\[{"id": 1, "permissions": ["r"]}, {"id": 2, "info": 5}]
    );
    try testing.expectEqualStrings(
        \\{"id":1,"type":"PipeWire:Interface:Client","version":4,"info":{"props":{"b":"2"},"state":"idle","change-mask":["props"]},"permissions":["r"]}
    , try stringify(arena, &fold, 1));
    try testing.expectEqualStrings(
        \\{"id":2,"type":"PipeWire:Interface:Node","info":5}
    , try stringify(arena, &fold, 2));

    // Gone, then back as something else: last, from scratch. Removing
    // what isn't there, and elements that aren't objects with an `id`, do nothing.
    _ = try fold.feed(
        \\[{"id": 1, "info": null}, {"id": 9, "info": null}, 3, {"id": "x"}, {"info": {}}]
    );
    try testing.expectEqualSlices(i64, &.{2}, fold.objects.keys());
    _ = try fold.feed(
        \\[{"id": 1, "type": "PipeWire:Interface:Port", "info": {"direction": "input"}}]
    );
    try testing.expectEqualSlices(i64, &.{ 2, 1 }, fold.objects.keys());
    try testing.expectEqualStrings(
        \\{"id":1,"type":"PipeWire:Interface:Port","info":{"direction":"input"}}
    , try stringify(arena, &fold, 1));
}

test "repeated keys keep the last value" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    _ = try fold.feed(
        \\[{"id": 1, "info": {"a": 1, "a": 2}}]
    );
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(
        \\{"id":1,"info":{"a":2}}
    , try stringify(arena_state.allocator(), &fold, 1));
}

test "what pw-dump doesn't write is an invalid dump" {
    const cases = [_][]const u8{
        "pw-dump: error",
        "{\"id\": 1}",
        "[{\"id\": 1,}]",
        "[1, 2}",
        "[\"x\" 1]",
    };
    for (cases) |c| {
        var fold: Fold = .init(testing.allocator);
        defer fold.deinit();
        try testing.expectError(error.InvalidDump, fold.feed(c));
    }
    // A number at the top level is not a batch either.
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    _ = try fold.feed("[]");
    try testing.expectError(error.InvalidDump, fold.feed("\n1"));
}

test "reset starts over, as for a new pw-dump" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    _ = try fold.feed("[{\"id\": 1, \"info\": {}}] [{\"id\": 2");
    fold.reset();
    try testing.expect(!fold.ready);
    try testing.expectEqual(0, fold.objects.count());
    try testing.expect(try fold.feed("[{\"id\": 3, \"info\": {}}]"));
    try testing.expectEqualSlices(i64, &.{3}, fold.objects.keys());
}

test "settled: Links made are there, Links undone are gone; ALSA ones don't count" {
    var fold: Fold = .init(testing.allocator);
    defer fold.deinit();
    _ = try fold.feed(
        \\[{"id": 50, "type": "PipeWire:Interface:Link", "info": {"output-port-id": 1, "input-port-id": 2}},
        \\ {"id": 51, "type": "PipeWire:Interface:Node", "info": {"output-port-id": 3, "input-port-id": 4}},
        \\ {"id": 52, "type": "PipeWire:Interface:Link", "info": null},
        \\ {"id": 53, "info": {}},
        \\ {"id": 54, "type": 5, "info": {}},
        \\ {"id": 55, "type": "PipeWire:Interface:Link"},
        \\ {"id": 56, "type": "PipeWire:Interface:Link", "info": []}]
    );
    const alsa: graph.Ends = .{ .alsa = .{ .{ .client = 20, .port = 0 }, .{ .client = 21, .port = 0 } } };
    try testing.expect(fold.settled(&.{}, &.{}));
    try testing.expect(fold.settled(&.{ .{ .pw = .{ 1, 2 } }, alsa }, &.{ .{ .pw = .{ 3, 4 } }, .{ .pw = .{ 2, 1 } }, alsa }));
    // Not a Link object: not made.
    try testing.expect(!fold.settled(&.{.{ .pw = .{ 3, 4 } }}, &.{}));
    try testing.expect(!fold.settled(&.{}, &.{.{ .pw = .{ 1, 2 } }}));

    // Once the monitor says so.
    _ = try fold.feed(
        \\[{"id": 50, "info": null}, {"id": 57, "type": "PipeWire:Interface:Link", "info": {"output-port-id": 3, "input-port-id": 4}}]
    );
    try testing.expect(fold.settled(&.{.{ .pw = .{ 3, 4 } }}, &.{.{ .pw = .{ 1, 2 } }}));
}

fn feedAndBuild(gpa: Allocator, chunks: []const []const u8) !void {
    var fold: Fold = .init(gpa);
    defer fold.deinit();
    for (chunks) |c| _ = try fold.feed(c);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    _ = try pipewire.build(arena_state.allocator(), try fold.values(arena_state.allocator()), .none);
}

test "out of memory at any allocation leaks nothing" {
    // A Node with Ports and a Link, updated, cut mid-batch, and partly removed.
    try testing.checkAllAllocationFailures(testing.allocator, feedAndBuild, .{@as([]const []const u8, &.{
        \\[{"id": 1, "type": "PipeWire:Interface:Node", "info": {"props": {"node.name": "n", "media.class": "Audio/Sink"}}},
        \\ {"id": 2, "type": "PipeWire:Interface:Port", "info": {"direction": "input", "props": {"node.id": 1, "port.name": "in_FL", "format.dsp": "32 bit float mono audio", "x": [1, 2.5, 1e999, null, true]}}},
        \\ {"id": 3, "type": "PipeWire:Interface:Port", "info": {"direction": "output", "props": {"node.id": 1, "port.name": "out_FL", "format.dsp": "32 bit float mono audio"}}},
        \\ {"id": 4, "type": "PipeWire:Interface:Link", "info": {"output-port-id": 3, "input-port-id": 2}}]
        \\[{"id": 1, "info": {"change-mask": ["props"], "props": {"node.name": "m"}}}, {"id": 4, "info": null}]
        \\[{"id": 5,
    })});
}

/// Overwrites what is freed, so reading it afterwards shows.
const Poisoning = struct {
    child: Allocator,

    fn allocator(p: *Poisoning) Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = Allocator.noRemap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const p: *Poisoning = @ptrCast(@alignCast(ctx));
        return p.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const p: *Poisoning = @ptrCast(@alignCast(ctx));
        return p.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const p: *Poisoning = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xaa);
        p.child.rawFree(memory, alignment, ret_addr);
    }
};

test "the Graph built doesn't point into the fold, which changes under it" {
    var poisoning: Poisoning = .{ .child = testing.allocator };
    var fold: Fold = .init(poisoning.allocator());
    defer fold.deinit();
    _ = try fold.feed(capture);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const g = try pipewire.build(arena, try fold.values(arena), .none);

    // Every object replaced (its old memory freed), then every one removed.
    var update: std.ArrayList(u8) = .empty;
    var removal: std.ArrayList(u8) = .empty;
    for (fold.objects.keys(), 0..) |id, i| {
        const sep = if (i == 0) "[" else ",";
        try update.print(arena, "{s}{{\"id\":{d},\"info\":{{\"props\":{{}}}}}}", .{ sep, id });
        try removal.print(arena, "{s}{{\"id\":{d},\"info\":null}}", .{ sep, id });
    }
    try update.append(arena, ']');
    try removal.append(arena, ']');
    _ = try fold.feed(update.items);
    _ = try fold.feed(removal.items);
    try testing.expectEqual(0, fold.objects.count());
    try testing.expectEqualDeep(try pipewire.parse(arena, capture_end, .none), g);
}
