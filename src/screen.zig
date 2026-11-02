//! What the TUI shows, as one string of styled text per terminal row, as the
//! script draws it (`draw`, `draw_columns`, `draw_conns`, `cell`). Nothing
//! here talks to the terminal; see `term.zig`.
//!
//!     aroute  profile: default (modified)   ● audio  ● MIDI     title
//!     ──────────────────────────────────────────────────────
//!       FROM                      │   TO                        body: scrolls
//!       ● USB Video Analog Stereo │   ● Speakers                with PgUp/PgDn
//!       …                                                       when it doesn't
//!       CONNECTIONS                                             fit
//!       ● play → Speakers
//!     ──────────────────────────────────────────────────────
//!     Esc Exit   1 Connect   2 Disconnect   …                   menu
//!     ✓ …                                                       status

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const graph = @import("graph.zig");
const text = @import("text.zig");

pub const style = struct {
    pub const audio = "\x1b[32m";
    pub const midi = "\x1b[33m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const off = "\x1b[0m";

    pub fn kind(k: graph.Kind) []const u8 {
        return switch (k) {
            .audio => audio,
            .midi => midi,
        };
    }
};

/// Writing to an `Allocating` writer fails only when out of memory.
pub const Error = Allocator.Error || Writer.Error;

fn dimLine(comptime s: []const u8) []const u8 {
    return "  " ++ style.dim ++ s ++ style.off;
}

pub const Size = struct {
    rows: usize,
    cols: usize,

    /// What the script assumes when the size is unknown.
    pub const fallback: Size = .{ .rows = 24, .cols = 80 };
};

/// Rows taken by the title, the two rules, the menu and the status line.
const chrome_rows = 5;

/// Rows left for the body.
pub fn bodyRows(size: Size) usize {
    return size.rows -| chrome_rows;
}

/// The status line: the result of the last action.
pub const Status = struct {
    text: []const u8 = "",
    err: bool = false,
};

pub const Home = struct {
    graph: graph.Graph,
    profile: []const u8,
    /// The current snapshot differs from the one the Profile was loaded or saved with.
    modified: bool,
    status: Status = .{},
    /// Index of the first body line shown; `view` keeps it in range.
    scroll: usize = 0,
};

/// The home screen, one string per row.
pub fn home(arena: Allocator, h: Home, size: Size) Error![]const []const u8 {
    return frame(arena, .{
        .title = try title(arena, h.profile, h.modified, size.cols),
        .body = try homeBody(arena, h.graph, size.cols),
        .scroll = h.scroll,
        .menu = home_menu,
        .status = h.status,
    }, size);
}

const home_menu = style.bold ++ "Esc" ++ style.off ++ " Exit   " ++
    style.bold ++ "1" ++ style.off ++ " Connect   " ++
    style.bold ++ "2" ++ style.off ++ " Disconnect   " ++
    style.bold ++ "3" ++ style.off ++ " Save profile   " ++
    style.bold ++ "4" ++ style.off ++ " Load profile   " ++
    style.bold ++ "5" ++ style.off ++ " Delete profile";

fn title(arena: Allocator, profile: []const u8, modified: bool, cols: usize) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    var l: text.Line = .init(&out.writer, cols);
    try l.text(style.bold ++ "aroute" ++ style.off ++ "  profile: " ++ style.bold);
    try l.text(profile);
    try l.text(style.off);
    if (modified) try l.text(" " ++ style.red ++ "(modified)" ++ style.off);
    try l.text("   " ++ style.audio ++ "● audio" ++ style.off ++ "  " ++ style.midi ++ "● MIDI" ++ style.off);
    return out.toOwnedSlice();
}

/// The parts of a screen, before they are fitted to its size.
pub const Frame = struct {
    title: []const u8,
    /// Every line, even those that don't fit; `scroll` says which are shown.
    body: []const []const u8,
    scroll: usize,
    menu: []const u8,
    status: Status,
};

/// Lays out `f` on a screen of `size`: one string per row, none wider than
/// the screen.
pub fn frame(arena: Allocator, f: Frame, size: Size) Error![]const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    const rule = try hr(arena, size.cols);
    try rows.append(arena, try cut(arena, f.title, size.cols));
    try rows.append(arena, rule);

    const height = bodyRows(size);
    const v = view(f.body.len, height, f.scroll);
    if (v.above > 0) try rows.append(arena, try more(arena, "↑", v.above, "PgUp", size.cols));
    for (f.body[v.start..][0..v.count]) |line| try rows.append(arena, try cut(arena, line, size.cols));
    if (v.below > 0) try rows.append(arena, try more(arena, "↓", v.below, "PgDn", size.cols));
    for (v.rows()..height) |_| try rows.append(arena, "");

    try rows.append(arena, rule);
    try rows.append(arena, try cut(arena, f.menu, size.cols));
    const status = if (f.status.err)
        try std.fmt.allocPrint(arena, style.red ++ "{s}" ++ style.off, .{f.status.text})
    else
        f.status.text;
    try rows.append(arena, try cut(arena, status, size.cols));
    // A screen too short for all of it shows what fits from the top.
    return rows.items[0..@min(rows.items.len, size.rows)];
}

fn hr(arena: Allocator, cols: usize) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(style.dim);
    for (0..cols) |_| try w.writeAll("─");
    try w.writeAll(style.off);
    return out.toOwnedSlice();
}

fn more(arena: Allocator, arrow: []const u8, n: usize, key: []const u8, cols: usize) Error![]const u8 {
    return cut(arena, try std.fmt.allocPrint(arena, style.dim ++ "  {s} {d} more ({s})" ++ style.off, .{ arrow, n, key }), cols);
}

/// `s` cut to `cols` columns, if it is wider.
fn cut(arena: Allocator, s: []const u8, cols: usize) Error![]const u8 {
    if (text.width(s) <= cols) return s;
    var out: Writer.Allocating = .init(arena);
    var l: text.Line = .init(&out.writer, cols);
    try l.text(s);
    return out.toOwnedSlice();
}

/// Which body lines are shown, and how many are left out above and below.
/// When not all fit, a row at the top and one at the bottom say how many
/// more there are, as long as that leaves a line to show.
pub const View = struct {
    start: usize,
    count: usize,
    /// Lines before `start`, said in a row of its own; 0 when there is no room for it.
    above: usize,
    /// Lines after the shown ones, said in a row of its own; 0 when there is no room for it.
    below: usize,

    /// Rows taken, counting the "more" rows.
    pub fn rows(v: View) usize {
        return v.count + @intFromBool(v.above > 0) + @intFromBool(v.below > 0);
    }
};

/// Shortest body that gets the "more" rows: one line between them.
const min_more_rows = 3;

/// The lines of a body of `total` lines shown in `height` rows, starting at
/// `scroll` (pulled back so the last page is full).
pub fn view(total: usize, height: usize, scroll: usize) View {
    if (total <= height) return .{ .start = 0, .count = total, .above = 0, .below = 0 };
    const start = @min(scroll, maxScroll(total, height));
    // No room to say what is left out.
    if (height < min_more_rows) return .{ .start = start, .count = height, .above = 0, .below = 0 };
    const room = height - @intFromBool(start > 0);
    const count = if (total - start <= room) total - start else room - 1;
    return .{ .start = start, .count = count, .above = start, .below = total - start - count };
}

/// The last `scroll` worth having: the one that shows the last line.
pub fn maxScroll(total: usize, height: usize) usize {
    if (total <= height) return 0;
    // The last page has a "more" row at the top.
    if (height < min_more_rows) return total - height;
    return total - (height - 1);
}

/// The `scroll` one page further down: the first line not shown now.
pub fn pageDown(total: usize, height: usize, scroll: usize) usize {
    // Nothing is shown, so there are no pages.
    if (height == 0) return 0;
    const v = view(total, height, scroll);
    return @min(v.start + v.count, maxScroll(total, height));
}

/// The `scroll` one page further up: the page that ends just above the
/// first line shown now, so it undoes `pageDown`.
pub fn pageUp(total: usize, height: usize, scroll: usize) usize {
    if (height == 0) return 0;
    const start = view(total, height, scroll).start;
    if (height < min_more_rows) return start -| height;
    // The top page shows `height - 1` lines; any other `height - 2`.
    if (start <= height - 1) return 0;
    return start - (height - 2);
}

/// The home body: the FROM and TO columns, then the Connections.
pub fn homeBody(arena: Allocator, g: graph.Graph, cols: usize) Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var sources: std.ArrayList(graph.Endpoint) = .empty;
    var destinations: std.ArrayList(graph.Endpoint) = .empty;
    for ([_]graph.Kind{ .audio, .midi }) |kind| {
        for (g.endpoints) |ep| {
            if (ep.hidden or ep.kind != kind) continue;
            try (if (ep.direction == .from) &sources else &destinations).append(arena, ep);
        }
    }

    const w = columnWidth(cols);
    try lines.append(arena, try row(arena, cols, try header(arena, "  FROM", w), try header(arena, "  TO", w)));
    if (sources.items.len == 0 and destinations.items.len == 0) {
        try lines.append(arena, dimLine("(no devices found)"));
    }
    for (0..@max(sources.items.len, destinations.items.len)) |i| {
        try lines.append(arena, try row(
            arena,
            cols,
            try cell(arena, if (i < sources.items.len) sources.items[i] else null, w),
            try cell(arena, if (i < destinations.items.len) destinations.items[i] else null, w),
        ));
    }
    try lines.append(arena, "");
    try lines.appendSlice(arena, try connections(arena, g, cols));
    return lines.items;
}

/// Width of each of the two columns, with ` │ ` between them.
pub fn columnWidth(cols: usize) usize {
    return (cols -| 3) / 2;
}

fn row(arena: Allocator, cols: usize, left: []const u8, right: []const u8) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    var l: text.Line = .init(&out.writer, cols);
    try l.text(left);
    try l.text(" " ++ style.dim ++ "│" ++ style.off ++ " ");
    try l.text(right);
    return out.toOwnedSlice();
}

fn header(arena: Allocator, name: []const u8, w: usize) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try out.writer.writeAll(style.bold);
    try text.fit(&out.writer, name, w);
    try out.writer.writeAll(style.off);
    return out.toOwnedSlice();
}

/// One column cell, `  ● label`, exactly `w` columns wide; blank for none.
fn cell(arena: Allocator, ep: ?graph.Endpoint, w: usize) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    var l: text.Line = .init(&out.writer, w);
    if (ep) |e| {
        try l.text("  ");
        try l.text(style.kind(e.kind));
        try l.text("● ");
        try l.text(e.label);
        try l.text(style.off);
    }
    try l.pad();
    return out.toOwnedSlice();
}

/// `  CONNECTIONS`, then `  ● source → destination` for each, coloured by Kind.
fn connections(arena: Allocator, g: graph.Graph, cols: usize) Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(arena, style.bold ++ "  CONNECTIONS" ++ style.off);
    if (g.connections.len == 0) try lines.append(arena, dimLine("(no connections)"));
    // As in the script: the Source padded to `w`, the Destination cut to it.
    const w = (cols -| 10) / 2;
    for (g.connections) |c| {
        const col = style.kind(g.endpoints[c.from].kind);
        var from: Writer.Allocating = .init(arena);
        try text.fit(&from.writer, g.endpoints[c.from].label, w);
        var out: Writer.Allocating = .init(arena);
        var l: text.Line = .init(&out.writer, cols);
        try l.text("  ");
        try l.text(col);
        try l.text("● ");
        try l.text(from.written());
        try l.text(style.off ++ " → ");
        try l.text(col);
        try l.text(try cut(arena, g.endpoints[c.to].label, w));
        try l.text(style.off);
        try lines.append(arena, try out.toOwnedSlice());
    }
    return lines.items;
}

const testing = std.testing;

/// `s` without its escape sequences.
fn plain(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i += 2;
            while (i < s.len and s[i] >= 0x20 and s[i] < 0x40) i += 1;
            i += 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// `n` box-drawing dashes.
fn dashes(arena: Allocator, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| try out.appendSlice(arena, "─");
    return out.items;
}

fn plainRows(arena: Allocator, rows: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, rows.len);
    for (rows, out) |r, *o| o.* = try plain(arena, r);
    return out;
}

fn expectRows(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

const fixture: graph.Graph = .{
    .endpoints = @constCast(&[_]graph.Endpoint{
        .{ .label = "USB Video Analog Stereo", .kind = .audio, .direction = .from, .ports = .{ .pw = &.{} } },
        .{ .label = "Speakers", .kind = .audio, .direction = .to, .ports = .{ .pw = &.{} } },
        .{ .label = "WORLDE", .kind = .midi, .direction = .from, .ports = .{ .alsa = .{ .addr = .{ .client = 128, .port = 0 } } } },
        .{ .label = "Clipper MIDI 2", .kind = .midi, .direction = .to, .ports = .{ .alsa = .{ .addr = .{ .client = 129, .port = 1 } } } },
        .{ .label = "Speakers · monitor", .kind = .audio, .direction = .from, .ports = .{ .pw = &.{} }, .hidden = true },
        .{ .label = "日本語のスピーカー", .kind = .audio, .direction = .to, .ports = .{ .pw = &.{} } },
    }),
    .connections = &.{
        .{ .from = 0, .to = 1, .links = &.{} },
        .{ .from = 2, .to = 5, .links = &.{} },
        .{ .from = 4, .to = 3, .links = &.{} },
    },
};

test "columnWidth: two columns and ` │ `, never negative" {
    try testing.expectEqual(38, columnWidth(80));
    try testing.expectEqual(18, columnWidth(40));
    try testing.expectEqual(18, columnWidth(39));
    try testing.expectEqual(0, columnWidth(4));
    try testing.expectEqual(0, columnWidth(0));
}

test "homeBody: audio before MIDI, hidden Endpoints left out, names cut by display width" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try homeBody(arena, fixture, 40);
    try expectRows(&.{
        "  FROM             │   TO              ",
        "  ● USB Video Ana… │   ● Speakers      ",
        "  ● WORLDE         │   ● 日本語のスピ… ",
        "                   │   ● Clipper MIDI 2",
        "",
        "  CONNECTIONS",
        "  ● USB Video Anal… → Speakers",
        "  ● WORLDE          → 日本語のスピー…",
        "  ● Speakers · mon… → Clipper MIDI 2",
    }, try plainRows(arena, body));
    for (body) |line| try testing.expect(text.width(line) <= 40);
    // Each cell is exactly one column wide, wide characters included.
    for (body[1..4]) |line| {
        const p = try plain(arena, line);
        const bar = std.mem.find(u8, p, "│").?;
        try testing.expectEqual(columnWidth(40) + 1, text.width(p[0..bar]));
    }
}

test "homeBody: colours by Kind, the Connection by its Source" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try homeBody(arena, fixture, 80);
    try testing.expect(std.mem.find(u8, body[1], style.audio ++ "● USB Video") != null);
    try testing.expect(std.mem.find(u8, body[2], style.midi ++ "● WORLDE") != null);
    try testing.expect(std.mem.find(u8, body[7], style.midi ++ "● WORLDE") != null);
    try testing.expect(std.mem.find(u8, body[7], style.midi ++ "日本語") != null);
}

test "homeBody: nothing found" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try homeBody(arena, .{ .endpoints = &.{}, .connections = &.{} }, 30);
    try expectRows(&.{
        "  FROM        │   TO         ",
        "  (no devices found)",
        "",
        "  CONNECTIONS",
        "  (no connections)",
    }, try plainRows(arena, body));
}

test "home: title, rules, menu and status on a screen that fits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try home(arena, .{
        .graph = fixture,
        .profile = "Normal idle",
        .modified = true,
        .status = .{ .text = "✗ cannot read the PipeWire graph", .err = true },
    }, .{ .rows = 16, .cols = 50 });
    try testing.expectEqual(16, rows.len);
    const p = try plainRows(arena, rows);
    try testing.expectEqualStrings("aroute  profile: Normal idle (modified)   ● audio…", p[0]);
    try testing.expectEqualStrings(try dashes(arena, 50), p[1]);
    try testing.expectEqualStrings("  FROM                  │   TO                   ", p[2]);
    try testing.expectEqualStrings("  ● Speakers · monitor   → Clipper MIDI 2", p[10]);
    try testing.expectEqualStrings("", p[11]);
    try testing.expectEqualStrings(try dashes(arena, 50), p[13]);
    try testing.expectEqualStrings("Esc Exit   1 Connect   2 Disconnect   3 Save prof…", p[14]);
    try testing.expectEqualStrings("✗ cannot read the PipeWire graph", p[15]);
    try testing.expect(std.mem.startsWith(u8, rows[15], style.red));
    try testing.expect(std.mem.find(u8, rows[0], style.red ++ "(modified)") != null);

    const clean = try plainRows(arena, try home(arena, .{ .graph = fixture, .profile = "default", .modified = false }, .{ .rows = 16, .cols = 80 }));
    try testing.expectEqualStrings("aroute  profile: default   ● audio  ● MIDI", clean[0]);
    try testing.expectEqualStrings("Esc Exit   1 Connect   2 Disconnect   3 Save profile   4 Load profile   5 Delet…", clean[14]);
    try testing.expectEqualStrings("", clean[15]);
}

test "home: scrolled, with how many lines are above and below" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 9 body lines in 5 rows.
    const size: Size = .{ .rows = 10, .cols = 40 };
    const top = try plainRows(arena, try home(arena, .{ .graph = fixture, .profile = "default", .modified = false }, size));
    try expectRows(&.{
        "  FROM             │   TO              ",
        "  ● USB Video Ana… │   ● Speakers      ",
        "  ● WORLDE         │   ● 日本語のスピ… ",
        "                   │   ● Clipper MIDI 2",
        "  ↓ 5 more (PgDn)",
    }, top[2..7]);

    const middle = try plainRows(arena, try home(arena, .{ .graph = fixture, .profile = "default", .modified = false, .scroll = 4 }, size));
    try expectRows(&.{
        "  ↑ 4 more (PgUp)",
        "",
        "  CONNECTIONS",
        "  ● USB Video Anal… → Speakers",
        "  ↓ 2 more (PgDn)",
    }, middle[2..7]);

    // Past the end: pulled back to the last page.
    const bottom = try plainRows(arena, try home(arena, .{ .graph = fixture, .profile = "default", .modified = false, .scroll = 100 }, size));
    try expectRows(&.{
        "  ↑ 5 more (PgUp)",
        "  CONNECTIONS",
        "  ● USB Video Anal… → Speakers",
        "  ● WORLDE          → 日本語のスピー…",
        "  ● Speakers · mon… → Clipper MIDI 2",
    }, bottom[2..7]);
    try testing.expectEqualStrings(try dashes(arena, 40), bottom[7]);
}

test "home: a tiny terminal shows what fits, no row wider than the screen" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]Size{
        .{ .rows = 0, .cols = 0 }, .{ .rows = 1, .cols = 1 },  .{ .rows = 3, .cols = 5 },
        .{ .rows = 6, .cols = 2 }, .{ .rows = 7, .cols = 12 }, .{ .rows = 8, .cols = 3 },
    }) |size| {
        for ([_]usize{ 0, 1, 2, 50 }) |scroll| {
            const rows = try home(arena, .{ .graph = fixture, .profile = "default", .modified = true, .scroll = scroll }, size);
            try testing.expectEqual(size.rows, rows.len);
            for (rows) |r| try testing.expect(text.width(r) <= size.cols);
        }
    }
    const p = try plainRows(arena, try home(arena, .{ .graph = fixture, .profile = "default", .modified = false }, .{ .rows = 7, .cols = 12 }));
    try expectRows(&.{ "aroute  pro…", "────────────", "  F… │   TO", "  ●  │   ● ", "────────────", "Esc Exit   …", "" }, p);
}

test "view: everything fits" {
    try testing.expectEqual(View{ .start = 0, .count = 4, .above = 0, .below = 0 }, view(4, 5, 0));
    try testing.expectEqual(View{ .start = 0, .count = 5, .above = 0, .below = 0 }, view(5, 5, 3));
    try testing.expectEqual(View{ .start = 0, .count = 0, .above = 0, .below = 0 }, view(0, 0, 0));
    try testing.expectEqual(0, maxScroll(5, 5));
}

test "view: a row each for the lines above and below" {
    // 20 lines in 6 rows: the top page shows 5, the middle ones 4, the last 5.
    try testing.expectEqual(View{ .start = 0, .count = 5, .above = 0, .below = 15 }, view(20, 6, 0));
    try testing.expectEqual(View{ .start = 5, .count = 4, .above = 5, .below = 11 }, view(20, 6, 5));
    try testing.expectEqual(15, maxScroll(20, 6));
    try testing.expectEqual(View{ .start = 15, .count = 5, .above = 15, .below = 0 }, view(20, 6, 15));
    try testing.expectEqual(View{ .start = 15, .count = 5, .above = 15, .below = 0 }, view(20, 6, 99));
    for ([_]usize{ 0, 5, 14, 15 }) |s| try testing.expectEqual(6, view(20, 6, s).rows());
}

test "view: too short for the \"more\" rows" {
    try testing.expectEqual(View{ .start = 0, .count = 2, .above = 0, .below = 0 }, view(10, 2, 0));
    try testing.expectEqual(View{ .start = 8, .count = 2, .above = 0, .below = 0 }, view(10, 2, 9));
    try testing.expectEqual(View{ .start = 0, .count = 0, .above = 0, .below = 0 }, view(10, 0, 0));
}

test "pageDown and pageUp: step a page, stop at the ends, undo each other" {
    const total = 20;
    const height = 6;
    var s: usize = 0;
    var downs: std.ArrayList(usize) = .empty;
    defer downs.deinit(testing.allocator);
    while (true) {
        try downs.append(testing.allocator, s);
        const next = pageDown(total, height, s);
        if (next == s) break;
        s = next;
    }
    try testing.expectEqualSlices(usize, &.{ 0, 5, 9, 13, 15 }, downs.items);
    // Every line is shown on some page.
    var shown: [total]bool = @splat(false);
    for (downs.items) |d| {
        const v = view(total, height, d);
        for (v.start..v.start + v.count) |i| shown[i] = true;
    }
    for (shown) |b| try testing.expect(b);

    try testing.expectEqual(9, pageUp(total, height, 13));
    try testing.expectEqual(5, pageUp(total, height, 9));
    try testing.expectEqual(0, pageUp(total, height, 5));
    try testing.expectEqual(0, pageUp(total, height, 3));
    try testing.expectEqual(0, pageUp(total, height, 0));
    try testing.expectEqual(11, pageUp(total, height, 15));
    // Out of range is pulled back first.
    try testing.expectEqual(11, pageUp(total, height, 99));
    // Everything fits: nowhere to go.
    try testing.expectEqual(0, pageDown(5, height, 0));
    try testing.expectEqual(0, pageUp(5, height, 0));
}

test "pageDown and pageUp: bodies too short for the \"more\" rows" {
    try testing.expectEqual(2, pageDown(10, 2, 0));
    try testing.expectEqual(8, pageDown(10, 2, 7));
    try testing.expectEqual(4, pageUp(10, 2, 6));
    try testing.expectEqual(0, pageUp(10, 2, 1));
    try testing.expectEqual(1, pageDown(10, 1, 0));
    try testing.expectEqual(0, pageDown(10, 0, 0));
    try testing.expectEqual(0, pageUp(10, 0, 0));
}
