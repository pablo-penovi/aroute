//! The interactive TUI, as the script's `tui`: for now the home screen,
//! re-read every second. Drawing is in `screen.zig`, the terminal in
//! `term.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const graph = @import("graph.zig");
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
    status: screen.Status = .{},
    /// The last re-read failed; the graph shown is the one before.
    unreadable: bool = false,
    scroll: usize = 0,

    /// Reads the graph; its snapshot is the baseline of the `default` Profile.
    pub fn init(gpa: Allocator, scanner: anytype) ScanError!App {
        var current: Scan = try .read(gpa, scanner);
        errdefer current.deinit();
        return .{ .gpa = gpa, .current = current, .baseline = try gpa.dupe(u8, current.snapshot) };
    }

    pub fn deinit(app: *App) void {
        app.current.deinit();
        app.gpa.free(app.baseline);
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
        app.current.deinit();
        app.current = fresh;
        app.unreadable = false;
    }

    pub fn modified(app: App) bool {
        return !std.mem.eql(u8, app.current.snapshot, app.baseline);
    }

    pub fn home(app: App) screen.Home {
        return .{
            .graph = app.current.graph,
            .profile = app.profile,
            .modified = app.modified(),
            .status = if (app.unreadable) .{ .text = unreadable, .err = true } else app.status,
            .scroll = app.scroll,
        };
    }

    pub const Action = enum { stay, quit };

    /// Handles a key on the home screen of `size`.
    pub fn key(app: *App, arena: Allocator, k: term.Key, size: screen.Size) screen.Error!Action {
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
            .char => |c| if (c >= '1' and c <= '5') {
                app.status = .{ .text = not_yet[c - '1'] };
            },
            else => {},
        }
        return .stay;
    }

    const not_yet = [_][]const u8{
        "Connect is not implemented yet",
        "Disconnect is not implemented yet",
        "Save profile is not implemented yet",
        "Load profile is not implemented yet",
        "Delete profile is not implemented yet",
    };
};

/// Runs the TUI until Esc. `scanner.scan(arena)` reads the graph; the first
/// read happens before the screen is taken over, so its error is the caller's.
pub fn run(gpa: Allocator, io: Io, scanner: anytype) !void {
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
        if (now(io) >= next_scan) {
            try app.refresh(scanner);
            next_scan = now(io) + refresh_ms;
        }
        _ = frame.reset(.retain_capacity);
        const size = term.size();
        try draw(&stdout.interface, try screen.home(frame.allocator(), app.home(), size), size, clear);
        clear = false;

        const wait: i32 = @intCast(std.math.clamp(next_scan - now(io), 0, refresh_ms));
        switch (input.next(wait) catch return) {
            .timeout => {},
            .resize => clear = true,
            .key => |k| if (try app.key(frame.allocator(), k, size) == .quit) return,
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

test "App: Esc quits, PgUp/PgDn scroll, the menu keys are not there yet" {
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
    try testing.expectEqual(.stay, try app.key(arena, .page_down, size));
    try testing.expectEqual(5, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_down, size));
    try testing.expectEqual(9, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_up, size));
    try testing.expectEqual(5, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_up, size));
    try testing.expectEqual(0, app.scroll);
    try testing.expectEqual(.stay, try app.key(arena, .page_up, size));
    try testing.expectEqual(0, app.scroll);
    for (0..10) |_| _ = try app.key(arena, .page_down, size);
    try testing.expectEqual(screen.maxScroll(24, 6), app.scroll);

    try testing.expectEqual(.stay, try app.key(arena, .{ .char = '1' }, size));
    try testing.expectEqualStrings("Connect is not implemented yet", app.home().status.text);
    try testing.expectEqual(.stay, try app.key(arena, .{ .char = '5' }, size));
    try testing.expectEqualStrings("Delete profile is not implemented yet", app.home().status.text);
    try testing.expectEqual(.stay, try app.key(arena, .{ .char = 'a' }, size));
    try testing.expectEqual(.stay, try app.key(arena, .enter, size));
    try testing.expectEqual(.quit, try app.key(arena, .esc, size));
}
