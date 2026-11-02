//! The interactive TUI, as the script's `tui`: the home screen, re-read
//! every second, and Connect. Drawing is in `screen.zig`, the terminal in
//! `term.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const graph = @import("graph.zig");
const connect = @import("connect.zig");
const picker = @import("picker.zig");
const screen = @import("screen.zig");
const term = @import("term.zig");

/// How often the home screen re-reads the graph, as the script's REFRESH.
const refresh_ms = 1000;

pub const ScanError = error{
    /// The graph could not be read, e.g. PipeWire is not running.
    Unreadable,
} || Allocator.Error;

pub const unreadable = "✗ cannot read the PipeWire graph (is PipeWire running?)";

/// One read of the graph, and the memory it lives in.
const Scan = struct {
    arena: std.heap.ArenaAllocator,
    graph: graph.Graph,
    /// The snapshot's lines, joined by `\n`.
    snapshot: []const u8,

    /// `scanner.scan(arena)` reads the graph into `arena`.
    fn read(gpa: Allocator, scanner: anytype) ScanError!Scan {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const g = try scanner.scan(a);
        const snapshot = try std.mem.join(a, "\n", try g.snapshot(a));
        return .{ .arena = arena, .graph = g, .snapshot = snapshot };
    }

    fn deinit(s: *Scan) void {
        s.arena.deinit();
    }
};

/// What the TUI shows, and what changes it.
pub const App = struct {
    gpa: Allocator,
    current: Scan,
    /// The snapshot the current Profile was loaded or saved with.
    baseline: []u8,
    profile: []const u8 = "default",
    /// The status line: the result of the last action.
    status_text: std.ArrayList(u8) = .empty,
    status_err: bool = false,
    /// The last re-read failed; the graph shown is the one before.
    unreadable: bool = false,
    /// The home screen's scroll.
    scroll: usize = 0,
    mode: Mode = .home,

    pub const Mode = union(enum) {
        home,
        connect: Picking,
    };

    /// Where Connect is at. The graph is not re-read meanwhile, so the
    /// letters stay on the same Endpoints.
    pub const Picking = struct {
        /// The column with the letters.
        focus: graph.Direction = .from,
        /// The focused column's page.
        page: usize = 0,
        /// The first pick, once there is one; the other column then lists
        /// only what it can be connected to.
        pick: ?usize = null,
        /// The page the first pick was on, to go back to.
        pick_page: usize = 0,
    };

    /// Reads the graph; its snapshot is the baseline of the `default` Profile.
    pub fn init(gpa: Allocator, scanner: anytype) ScanError!App {
        var current: Scan = try .read(gpa, scanner);
        errdefer current.deinit();
        return .{ .gpa = gpa, .current = current, .baseline = try gpa.dupe(u8, current.snapshot) };
    }

    pub fn deinit(app: *App) void {
        app.current.deinit();
        app.gpa.free(app.baseline);
        app.status_text.deinit(app.gpa);
    }

    /// Re-reads the graph. If it can't be read, the last one stays and the
    /// status line says so until a read works again.
    pub fn refresh(app: *App, scanner: anytype) Allocator.Error!void {
        const fresh = Scan.read(app.gpa, scanner) catch |err| switch (err) {
            error.Unreadable => {
                app.unreadable = true;
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        app.replace(fresh);
    }

    fn replace(app: *App, fresh: Scan) void {
        app.current.deinit();
        app.current = fresh;
        app.unreadable = false;
    }

    pub fn modified(app: App) bool {
        return !std.mem.eql(u8, app.current.snapshot, app.baseline);
    }

    pub fn status(app: App) screen.Status {
        if (app.unreadable) return .{ .text = unreadable, .err = true };
        return .{ .text = app.status_text.items, .err = app.status_err };
    }

    fn say(app: *App, err: bool, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        app.status_text.clearRetainingCapacity();
        try app.status_text.print(app.gpa, fmt, args);
        app.status_err = err;
    }

    /// Whether the graph is re-read every second: on the home screen only.
    pub fn live(app: App) bool {
        return app.mode == .home;
    }

    pub fn home(app: App) screen.Home {
        return .{
            .graph = app.current.graph,
            .profile = app.profile,
            .modified = app.modified(),
            .status = app.status(),
            .scroll = app.scroll,
        };
    }

    /// The Connect screen, with only the Endpoints that can be picked in
    /// the focused column. Only while picking.
    pub fn connectScreen(app: App, arena: Allocator) Allocator.Error!screen.Connect {
        const p = app.mode.connect;
        const g = app.current.graph;
        var from = try screen.column(arena, g, .from);
        var to = try screen.column(arena, g, .to);
        const list = if (p.focus == .from) &from else &to;
        var pickable: std.ArrayList(usize) = .empty;
        for (list.*) |ep| {
            const ok = if (p.pick) |first| connect.validEither(g, first, ep) else connect.hasPartner(g, ep);
            if (ok) try pickable.append(arena, ep);
        }
        list.* = pickable.items;
        return .{
            .graph = g,
            .profile = app.profile,
            .modified = app.modified(),
            .status = app.status(),
            .focus = p.focus,
            .from = from,
            .to = to,
            .page = p.page,
            .pick = p.pick,
        };
    }

    /// The screen of `size`, one string per row.
    pub fn rows(app: App, arena: Allocator, size: screen.Size) screen.Error![]const []const u8 {
        return switch (app.mode) {
            .home => screen.home(arena, app.home(), size),
            .connect => screen.connect(arena, try app.connectScreen(arena), size),
        };
    }

    pub const Action = enum { stay, quit };

    /// Handles a key on a screen of `size`. `scanner` re-reads the graph
    /// and `wiring.connect(arena, ends)` makes a Link, returning why it
    /// failed (or null), as `run` takes them.
    pub fn key(app: *App, arena: Allocator, k: term.Key, size: screen.Size, scanner: anytype, wiring: anytype) !Action {
        switch (app.mode) {
            .home => return app.homeKey(arena, k, size),
            .connect => try app.connectKey(arena, k, size, scanner, wiring),
        }
        return .stay;
    }

    fn homeKey(app: *App, arena: Allocator, k: term.Key, size: screen.Size) screen.Error!Action {
        switch (k) {
            .esc => return .quit,
            .page_down, .page_up => {
                const total = (try screen.homeBody(arena, app.current.graph, size.cols)).len;
                const height = screen.bodyRows(size);
                app.scroll = if (k == .page_down)
                    screen.pageDown(total, height, app.scroll)
                else
                    screen.pageUp(total, height, app.scroll);
            },
            .char => |c| switch (c) {
                '1' => {
                    app.status_text.clearRetainingCapacity();
                    app.mode = .{ .connect = .{} };
                },
                '2'...'5' => try app.say(false, "{s}", .{not_yet[c - '2']}),
                else => {},
            },
            else => {},
        }
        return .stay;
    }

    const not_yet = [_][]const u8{
        "Disconnect is not implemented yet",
        "Save profile is not implemented yet",
        "Load profile is not implemented yet",
        "Delete profile is not implemented yet",
    };

    fn connectKey(app: *App, arena: Allocator, k: term.Key, size: screen.Size, scanner: anytype, wiring: anytype) !void {
        const p = &app.mode.connect;
        switch (k) {
            .esc => if (p.pick != null) {
                p.* = .{ .focus = other(p.focus), .page = p.pick_page };
            } else {
                app.mode = .home;
            },
            .tab => if (p.pick == null) {
                p.* = .{ .focus = other(p.focus) };
            },
            .page_down, .page_up => {
                const pages: picker.Pages = .init((try app.focused(arena)).len, screen.pickRows(size));
                p.page = if (k == .page_down) pages.next(p.page) else pages.prev(p.page);
            },
            .char => |c| {
                const list = try app.focused(arena);
                const pages: picker.Pages = .init(list.len, screen.pickRows(size));
                const ep = list[pages.pick(p.page, c) orelse return];
                if (p.pick) |first| {
                    app.mode = .home;
                    try app.connectPicked(arena, first, ep, scanner, wiring);
                } else {
                    p.* = .{ .focus = other(p.focus), .pick = ep, .pick_page = pages.clamp(p.page) };
                }
            },
            else => {},
        }
    }

    /// What can be picked in the focused column, top to bottom.
    fn focused(app: App, arena: Allocator) Allocator.Error![]const usize {
        const c = try app.connectScreen(arena);
        return if (c.focus == .from) c.from else c.to;
    }

    /// Re-reads the graph and, if both picks are still there, connects them.
    fn connectPicked(app: *App, arena: Allocator, a: usize, b: usize, scanner: anytype, wiring: anytype) !void {
        const old = app.current.graph;
        const pair: [2]graph.Endpoint = if (old.endpoints[a].direction == .from)
            .{ old.endpoints[a], old.endpoints[b] }
        else
            .{ old.endpoints[b], old.endpoints[a] };
        const fresh = Scan.read(app.gpa, scanner) catch |err| switch (err) {
            error.Unreadable => {
                app.unreadable = true;
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        // The first pick first.
        const order: [2]usize = if (old.endpoints[a].direction == .from) .{ 0, 1 } else .{ 1, 0 };
        var found: [2]usize = undefined;
        const gone: ?[]const u8 = for (order) |i| {
            found[i] = connect.find(fresh.graph, pair[i]) orelse break pair[i].label;
        } else null;
        if (gone) |label| {
            // `label` is in the old graph, which goes once the status is said.
            defer app.replace(fresh);
            return app.say(true, "✗ {s} is gone", .{label});
        }
        app.replace(fresh);

        const g = app.current.graph;
        const from = g.endpoints[found[0]].label;
        const to = g.endpoints[found[1]].label;
        const ends = connect.links(arena, g, found[0], found[1]) catch |err| switch (err) {
            error.NoRoutablePorts => return app.say(true, "✗ {s} → {s}: no routable ports", .{ from, to }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        var why: ?[]const u8 = null;
        for (ends) |e| {
            if (try wiring.connect(arena, e)) |reason| why = reason;
        }
        if (why) |reason| {
            try app.say(true, "✗ {s} → {s}: {s}", .{ from, to, reason });
        } else {
            try app.say(false, "✓ {s} → {s}", .{ from, to });
        }
        // Show the new Connection now, as the script does.
        try app.refresh(scanner);
    }
};

fn other(d: graph.Direction) graph.Direction {
    return if (d == .from) .to else .from;
}

/// Runs the TUI until Esc. `scanner.scan(arena)` reads the graph; the first
/// read happens before the screen is taken over, so its error is the
/// caller's. `wiring.connect(arena, ends)` makes a Link and returns null, or
/// why it could not, allocated in `arena`.
pub fn run(gpa: Allocator, io: Io, scanner: anytype, wiring: anytype) !void {
    var app: App = try .init(gpa, scanner);
    defer app.deinit();

    try term.enter();
    defer term.restore();

    var out_buf: [16 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();
    var input: term.Input = .{};
    var next_scan = now(io) + refresh_ms;
    var clear = false;

    while (true) {
        if (app.live() and now(io) >= next_scan) {
            try app.refresh(scanner);
            next_scan = now(io) + refresh_ms;
        }
        _ = frame.reset(.retain_capacity);
        const size = term.size();
        try draw(&stdout.interface, try app.rows(frame.allocator(), size), size, clear);
        clear = false;

        // While picking, the graph stays as it is: wait for a key.
        const wait: i32 = if (app.live()) @intCast(std.math.clamp(next_scan - now(io), 0, refresh_ms)) else -1;
        switch (input.next(wait) catch return) {
            .timeout => {},
            .resize => clear = true,
            .key => |k| {
                const was_live = app.live();
                if (try app.key(frame.allocator(), k, size, scanner, wiring) == .quit) return;
                // Back home: re-read after a full second, as after any other key.
                if (app.live() and !was_live) next_scan = now(io) + refresh_ms;
            },
        }
    }
}

fn now(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// Writes every row in place, clearing what is left of it.
fn draw(w: *Io.Writer, rows: []const []const u8, size: screen.Size, clear: bool) Io.Writer.Error!void {
    if (clear) try w.writeAll("\x1b[2J");
    for (rows, 1..) |r, i| {
        try w.print("\x1b[{d};1H{s}", .{ i, r });
        // A full row leaves the cursor on its last character, which `\e[K` would erase.
        if (@import("text.zig").width(r) < size.cols) try w.writeAll("\x1b[K");
    }
    try w.flush();
}

const testing = std.testing;

/// Hands out graphs in turn; `null` is a failed read.
const FakeScanner = struct {
    graphs: []const ?graph.Graph,
    next: *usize,

    pub fn scan(s: FakeScanner, arena: Allocator) ScanError!graph.Graph {
        _ = arena;
        const i = @min(s.next.*, s.graphs.len - 1);
        s.next.* += 1;
        return s.graphs[i] orelse error.Unreadable;
    }
};

/// For keys that never make a Link.
const NoWiring = struct {
    pub fn connect(_: NoWiring, _: Allocator, _: graph.Ends) Allocator.Error!?[]const u8 {
        unreachable;
    }
};

const pw_ep = graph.Endpoint{ .label = "x", .kind = .audio, .direction = .from, .ports = .{ .pw = &.{} } };

var two_eps = [_]graph.Endpoint{ pw_ep, pw_ep };

fn connected(comptime links: []const graph.Link) graph.Graph {
    const connections = comptime if (links.len == 0) &[_]graph.Connection{} else &[_]graph.Connection{.{ .from = 0, .to = 1, .links = links }};
    return .{ .endpoints = &two_eps, .connections = connections };
}

const link_a = [_]graph.Link{.{ .ends = .{ .pw = .{ 1, 2 } }, .from_name = "pw:a:out", .to_name = "pw:b:in" }};
const link_b = [_]graph.Link{.{ .ends = .{ .pw = .{ 3, 2 } }, .from_name = "pw:c:out", .to_name = "pw:b:in" }};

test "App: (modified) while the snapshot differs from the one at startup" {
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{ connected(&link_a), connected(&link_b), connected(&.{}), connected(&link_a) }, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    try testing.expectEqualStrings("default", app.home().profile);
    try testing.expect(!app.home().modified);
    try app.refresh(scanner);
    try testing.expect(app.home().modified);
    try app.refresh(scanner);
    try testing.expect(app.home().modified);
    try app.refresh(scanner);
    try testing.expect(!app.home().modified);
}

test "App: a failed re-read keeps the last graph and says so until one works" {
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{ connected(&link_a), null, connected(&link_b) }, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    try app.refresh(scanner);
    try testing.expectEqualStrings(unreadable, app.home().status.text);
    try testing.expect(app.home().status.err);
    try testing.expectEqual(1, app.home().graph.connections.len);
    try testing.expect(!app.home().modified);

    try app.refresh(scanner);
    try testing.expectEqualStrings("", app.home().status.text);
    try testing.expect(app.home().modified);
}

fn initAndRefresh(gpa: Allocator) !void {
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{ connected(&link_a), connected(&link_b) }, .next = &n };
    var app: App = try .init(gpa, scanner);
    defer app.deinit();
    try app.refresh(scanner);
}

test "App: running out of memory leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, initAndRefresh, .{});
}

test "App: the first read failing is an error" {
    var n: usize = 0;
    try testing.expectError(error.Unreadable, App.init(testing.allocator, FakeScanner{ .graphs = &.{null}, .next = &n }));
}

test "App: Esc quits, PgUp/PgDn scroll, the other menu keys are not there yet" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var endpoints: [20]graph.Endpoint = @splat(pw_ep);
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{.{ .endpoints = &endpoints, .connections = &.{} }}, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    // 24 body lines in 6 rows.
    const size: screen.Size = .{ .rows = 11, .cols = 40 };
    try testing.expectEqual(.stay, try app.key(arena, .page_down, size, scanner, NoWiring{}));
    try testing.expectEqual(5, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_down, size, scanner, NoWiring{}));
    try testing.expectEqual(9, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_up, size, scanner, NoWiring{}));
    try testing.expectEqual(5, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_up, size, scanner, NoWiring{}));
    try testing.expectEqual(0, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_up, size, scanner, NoWiring{}));
    try testing.expectEqual(0, app.scroll);
    for (0..10) |_| _ = try app.key(arena, .page_down, size, scanner, NoWiring{});
    try testing.expectEqual(screen.maxScroll(24, 6), app.scroll);

    try testing.expectEqual(.stay, try app.key(arena, .{ .char = '2' }, size, scanner, NoWiring{}));
    try testing.expectEqualStrings("Disconnect is not implemented yet", app.home().status.text);
    try testing.expectEqual(.stay, try app.key(arena, .{ .char = '5' }, size, scanner, NoWiring{}));
    try testing.expectEqualStrings("Delete profile is not implemented yet", app.home().status.text);
    try testing.expectEqual(.stay, try app.key(arena, .{ .char = 'a' }, size, scanner, NoWiring{}));
    try testing.expectEqual(.stay, try app.key(arena, .enter, size, scanner, NoWiring{}));
    try testing.expectEqual(.quit, try app.key(arena, .esc, size, scanner, NoWiring{}));
}

/// Records the Links it is asked to make; fails those in `fail`.
const FakeWiring = struct {
    made: *std.ArrayList(graph.Ends),
    fail: []const graph.Ends = &.{},

    pub fn connect(w: FakeWiring, arena: Allocator, e: graph.Ends) Allocator.Error!?[]const u8 {
        for (w.fail) |f| if (std.meta.eql(f, e)) return "failed to link ports: No such file or directory";
        try w.made.append(arena, e);
        return null;
    }
};

fn pwEp(label: []const u8, kind: graph.Kind, direction: graph.Direction, ports: []const u32) graph.Endpoint {
    return .{ .label = label, .kind = kind, .direction = direction, .ports = .{ .pw = ports } };
}

const studio_list = [_]graph.Endpoint{
    pwEp("Mic", .audio, .from, &.{1}), // 0
    pwEp("Synth", .audio, .from, &.{ 2, 3 }), // 1
    pwEp("Speakers", .audio, .to, &.{ 4, 5 }), // 2
    pwEp("Headphones", .audio, .to, &.{ 6, 7 }), // 3
    // No Midi-Bridge port, so it can't reach the PipeWire-only BLE MIDI.
    .{ .label = "Keys", .kind = .midi, .direction = .from, .ports = .{ .alsa = .{ .addr = .{ .client = 128, .port = 0 } } } }, // 4
    pwEp("BLE MIDI", .midi, .to, &.{8}), // 5
};
var studio_eps = studio_list;

/// Synth is connected to Speakers.
const studio: graph.Graph = .{ .endpoints = &studio_eps, .connections = &.{.{ .from = 1, .to = 2, .links = &.{} }} };

var studio_without_synth_eps = [_]graph.Endpoint{ studio_list[0], studio_list[2], studio_list[3], studio_list[4], studio_list[5] };
const studio_without_synth: graph.Graph = .{ .endpoints = &studio_without_synth_eps, .connections = &.{} };

// Everything moved: the same Endpoints at other indexes.
var studio_shuffled_eps = [_]graph.Endpoint{ studio_list[5], studio_list[3], studio_list[2], studio_list[1], studio_list[0], studio_list[4] };
const studio_shuffled: graph.Graph = .{ .endpoints = &studio_shuffled_eps, .connections = &.{.{ .from = 3, .to = 2, .links = &.{} }} };

const big: screen.Size = .{ .rows = 24, .cols = 80 };

/// The focused column's labels, top to bottom.
fn focusedLabels(app: App, arena: Allocator) ![]const []const u8 {
    const list = try app.focused(arena);
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |ep, *o| o.* = app.current.graph.endpoints[ep].label;
    return out;
}

fn expectLabels(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "Connect: from a Source, only what it can be connected to, then connect" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made };
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{ studio, studio_shuffled, studio }, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    _ = try app.key(arena, .{ .char = '1' }, big, scanner, wiring);
    try testing.expect(!app.live());
    try testing.expectEqual(.from, app.mode.connect.focus);
    // Keys has nothing it can be connected to.
    try expectLabels(&.{ "Mic", "Synth" }, try focusedLabels(app, arena));
    // Not a letter on screen.
    _ = try app.key(arena, .{ .char = 'c' }, big, scanner, wiring);
    try testing.expectEqual(null, app.mode.connect.pick);

    _ = try app.key(arena, .{ .char = 'b' }, big, scanner, wiring);
    try testing.expectEqual(.to, app.mode.connect.focus);
    try testing.expectEqual(1, app.mode.connect.pick);
    // Speakers is already connected to Synth; BLE MIDI is MIDI.
    try expectLabels(&.{"Headphones"}, try focusedLabels(app, arena));
    // No switching columns once picked.
    _ = try app.key(arena, .tab, big, scanner, wiring);
    try testing.expectEqual(.to, app.mode.connect.focus);

    // The graph is re-read first: the same Endpoints, at other indexes.
    _ = try app.key(arena, .{ .char = 'a' }, big, scanner, wiring);
    try testing.expect(app.live());
    try testing.expectEqualDeep(&[_]graph.Ends{ .{ .pw = .{ 2, 6 } }, .{ .pw = .{ 3, 7 } } }, made.items);
    try testing.expectEqualStrings("✓ Synth → Headphones", app.home().status.text);
    try testing.expect(!app.home().status.err);
    // Re-read again, to show the new Connection.
    try testing.expectEqual(3, n);
}

test "Connect: Tab starts from a Destination" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made };
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{studio}, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    _ = try app.key(arena, .{ .char = '1' }, big, scanner, wiring);
    _ = try app.key(arena, .tab, big, scanner, wiring);
    try testing.expectEqual(.to, app.mode.connect.focus);
    // BLE MIDI can only be fed by Keys, which has no Midi-Bridge port.
    try expectLabels(&.{ "Speakers", "Headphones" }, try focusedLabels(app, arena));
    _ = try app.key(arena, .tab, big, scanner, wiring);
    try testing.expectEqual(.from, app.mode.connect.focus);
    _ = try app.key(arena, .tab, big, scanner, wiring);

    _ = try app.key(arena, .{ .char = 'a' }, big, scanner, wiring);
    try testing.expectEqual(.from, app.mode.connect.focus);
    try expectLabels(&.{"Mic"}, try focusedLabels(app, arena));
    _ = try app.key(arena, .{ .char = 'a' }, big, scanner, wiring);
    // Mono fans out.
    try testing.expectEqualDeep(&[_]graph.Ends{ .{ .pw = .{ 1, 4 } }, .{ .pw = .{ 1, 5 } } }, made.items);
    try testing.expectEqualStrings("✓ Mic → Speakers", app.home().status.text);
}

test "Connect: a pick that is gone by the time it connects" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made };

    // The first pick (Synth) or the second (from a Destination first) unplugged.
    for ([_]bool{ false, true }) |from_destination| {
        var n: usize = 0;
        const scanner: FakeScanner = .{ .graphs = &.{ studio, studio_without_synth }, .next = &n };
        var app: App = try .init(testing.allocator, scanner);
        defer app.deinit();
        _ = try app.key(arena, .{ .char = '1' }, big, scanner, wiring);
        if (from_destination) {
            _ = try app.key(arena, .tab, big, scanner, wiring);
            _ = try app.key(arena, .{ .char = 'b' }, big, scanner, wiring); // Headphones
            _ = try app.key(arena, .{ .char = 'b' }, big, scanner, wiring); // Synth
        } else {
            _ = try app.key(arena, .{ .char = 'b' }, big, scanner, wiring); // Synth
            _ = try app.key(arena, .{ .char = 'a' }, big, scanner, wiring); // Headphones
        }
        try testing.expectEqualStrings("✗ Synth is gone", app.home().status.text);
        try testing.expect(app.home().status.err);
        try testing.expect(app.live());
        // What is shown is the fresh graph.
        try testing.expectEqual(5, app.home().graph.endpoints.len);
    }
    try testing.expectEqual(0, made.items.len);
}

test "Connect: a Link the tool can't make" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made, .fail = &.{.{ .pw = .{ 1, 5 } }} };
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{studio}, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    for ("1aa") |c| _ = try app.key(arena, .{ .char = c }, big, scanner, wiring);
    try testing.expectEqualStrings("✗ Mic → Speakers: failed to link ports: No such file or directory", app.home().status.text);
    try testing.expect(app.home().status.err);
    // The other Link is still made.
    try testing.expectEqualDeep(&[_]graph.Ends{.{ .pw = .{ 1, 4 } }}, made.items);
}

test "Connect: the graph can't be re-read" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made };
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{ studio, null }, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    for ("1aa") |c| _ = try app.key(arena, .{ .char = c }, big, scanner, wiring);
    try testing.expectEqualStrings(unreadable, app.home().status.text);
    try testing.expect(app.live());
    try testing.expectEqual(0, made.items.len);
}

test "Connect: Esc goes back a step, then home" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made };
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{studio}, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    try app.say(false, "✓ earlier", .{});
    _ = try app.key(arena, .{ .char = '1' }, big, scanner, wiring);
    try testing.expectEqualStrings("", app.status().text);
    _ = try app.key(arena, .tab, big, scanner, wiring);
    _ = try app.key(arena, .{ .char = 'b' }, big, scanner, wiring);
    try testing.expectEqual(.from, app.mode.connect.focus);
    try testing.expectEqual(.stay, try app.key(arena, .esc, big, scanner, wiring));
    try testing.expectEqualDeep(App.Picking{ .focus = .to }, app.mode.connect);
    try testing.expectEqual(.stay, try app.key(arena, .esc, big, scanner, wiring));
    try testing.expect(app.live());
    try testing.expectEqual(0, made.items.len);
    try testing.expectEqual(1, n);
}

test "Connect: PgUp/PgDn page the focused column, letters from `a` on each page" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 60 Sources and one Destination.
    var eps: [61]graph.Endpoint = undefined;
    for (eps[0..60], 0..) |*ep, i| ep.* = pwEp(try std.fmt.allocPrint(arena, "Source {d}", .{i}), .audio, .from, try arena.dupe(u32, &.{@intCast(i)}));
    eps[60] = pwEp("Speakers", .audio, .to, &.{100});
    var made: std.ArrayList(graph.Ends) = .empty;
    const wiring: FakeWiring = .{ .made = &made };
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{.{ .endpoints = &eps, .connections = &.{} }}, .next = &n };
    var app: App = try .init(testing.allocator, scanner);
    defer app.deinit();

    // 12 rows: 7 for the body, 4 for the columns.
    const small: screen.Size = .{ .rows = 12, .cols = 60 };
    try testing.expectEqual(4, screen.pickRows(small));
    _ = try app.key(arena, .{ .char = '1' }, small, scanner, wiring);
    _ = try app.key(arena, .page_up, small, scanner, wiring);
    try testing.expectEqual(0, app.mode.connect.page);
    for (0..3) |_| _ = try app.key(arena, .page_down, small, scanner, wiring);
    try testing.expectEqual(3, app.mode.connect.page);
    // Only 4 letters on screen.
    _ = try app.key(arena, .{ .char = 'e' }, small, scanner, wiring);
    try testing.expectEqual(null, app.mode.connect.pick);
    _ = try app.key(arena, .{ .char = 'b' }, small, scanner, wiring);
    try testing.expectEqual(13, app.mode.connect.pick);
    try testing.expectEqual(3, app.mode.connect.pick_page);
    try testing.expectEqual(0, app.mode.connect.page);
    // Back to the page it was picked on.
    _ = try app.key(arena, .esc, small, scanner, wiring);
    try testing.expectEqual(3, app.mode.connect.page);

    // The last page; past it, nothing changes.
    for (0..20) |_| _ = try app.key(arena, .page_down, small, scanner, wiring);
    try testing.expectEqual(14, app.mode.connect.page);
    _ = try app.key(arena, .{ .char = 'a' }, small, scanner, wiring);
    try testing.expectEqual(56, app.mode.connect.pick);
    _ = try app.key(arena, .{ .char = 'a' }, small, scanner, wiring);
    try testing.expectEqualDeep(&[_]graph.Ends{.{ .pw = .{ 56, 100 } }}, made.items);
    try testing.expectEqualStrings("✓ Source 56 → Speakers", app.home().status.text);
}

fn connectAndFail(gpa: Allocator, gone: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var made: std.ArrayList(graph.Ends) = .empty;
    var n: usize = 0;
    const scanner: FakeScanner = .{ .graphs = &.{ studio, if (gone) studio_without_synth else studio_shuffled }, .next = &n };
    var app: App = try .init(gpa, scanner);
    defer app.deinit();
    for ("1ba") |c| _ = try app.key(arena, .{ .char = c }, big, scanner, FakeWiring{ .made = &made });
}

test "Connect: running out of memory leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, connectAndFail, .{false});
    try testing.checkAllAllocationFailures(testing.allocator, connectAndFail, .{true});
}
