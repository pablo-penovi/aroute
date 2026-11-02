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
const picker = @import("picker.zig");
const text = @import("text.zig");

pub const style = struct {
    pub const audio = "\x1b[32m";
    pub const midi = "\x1b[33m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const cyan = "\x1b[36m";
    pub const reverse = "\x1b[7m";
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
    const sources = try column(arena, g, .from);
    const destinations = try column(arena, g, .to);

    const w = columnWidth(cols);
    try lines.append(arena, try row(arena, cols, try header(arena, "  FROM", w), try header(arena, "  TO", w)));
    if (sources.len == 0 and destinations.len == 0) {
        try lines.append(arena, dimLine("(no devices found)"));
    }
    for (0..@max(sources.len, destinations.len)) |i| {
        try lines.append(arena, try row(
            arena,
            cols,
            try cell(arena, if (i < sources.len) g.endpoints[sources[i]] else null, w, .plain),
            try cell(arena, if (i < destinations.len) g.endpoints[destinations[i]] else null, w, .plain),
        ));
    }
    try lines.append(arena, "");
    try lines.appendSlice(arena, try connections(arena, g, cols));
    return lines.items;
}

/// The Endpoints shown in the FROM or TO column, as indexes into
/// `g.endpoints`: audio before MIDI, hidden ones left out.
pub fn column(arena: Allocator, g: graph.Graph, direction: graph.Direction) Allocator.Error![]const usize {
    var list: std.ArrayList(usize) = .empty;
    for ([_]graph.Kind{ .audio, .midi }) |kind| {
        for (g.endpoints, 0..) |ep, i| {
            if (!ep.hidden and ep.kind == kind and ep.direction == direction) try list.append(arena, i);
        }
    }
    return list.items;
}

/// Picking Endpoints to connect: the columns get the whole body, and the
/// Connections are summed up in one line.
pub const Connect = struct {
    graph: graph.Graph,
    profile: []const u8,
    modified: bool,
    status: Status = .{},
    /// The column with the letters; the other is dimmed.
    focus: graph.Direction,
    /// Indexes into `graph.endpoints`, top to bottom. In the focused column
    /// only the Endpoints that can be picked; in the other, all of them.
    from: []const usize,
    to: []const usize,
    /// The focused column's page.
    page: usize = 0,
    /// The first pick, shown in reverse video; null until there is one.
    pick: ?usize = null,

    fn list(c: Connect, direction: graph.Direction) []const usize {
        return if (direction == .from) c.from else c.to;
    }
};

/// Rows each column gets on the Connect screen: the body less the column
/// header, the blank line and the summary.
pub fn pickRows(size: Size) usize {
    return bodyRows(size) -| 3;
}

/// The Connect screen, one string per row.
pub fn connect(arena: Allocator, c: Connect, size: Size) Error![]const []const u8 {
    const rows = pickRows(size);
    const w = columnWidth(size.cols);
    const unfocused: graph.Direction = if (c.focus == .from) .to else .from;
    const focused_pages: picker.Pages = .init(c.list(c.focus).len, rows);
    const other_pages: picker.Pages = .init(c.list(unfocused).len, rows);
    // The other column shows the page with the first pick on it.
    const other_page = if (c.pick) |p| (if (std.mem.findScalar(usize, c.list(unfocused), p)) |i| other_pages.pageOf(i) else 0) else 0;
    const shown = [2]picker.Pages.Slice{ focused_pages.slice(c.page), other_pages.slice(other_page) };

    var lines: std.ArrayList([]const u8) = .empty;
    var headers: [2][]const u8 = undefined;
    for ([_]graph.Direction{ .from, .to }, &headers) |d, *h| {
        const name = if (d == .from) "  FROM" else "  TO";
        h.* = try header(arena, if (d == c.focus and focused_pages.count() > 1)
            try std.fmt.allocPrint(arena, "{s}  {d}/{d}", .{ name, focused_pages.clamp(c.page) + 1, focused_pages.count() })
        else
            name, w);
    }
    try lines.append(arena, try row(arena, size.cols, headers[0], headers[1]));

    const nothing = shown[0].len == 0;
    const count = @min(rows, @max(shown[0].len, shown[1].len, @intFromBool(nothing)));
    for (0..count) |i| {
        var cells: [2][]const u8 = undefined;
        for ([_]graph.Direction{ .from, .to }, &cells) |d, *cl| {
            const focused = d == c.focus;
            const s = if (focused) shown[0] else shown[1];
            if (focused and nothing and i == 0) {
                cl.* = try cell(arena, null, w, .{ .note = "(nothing to connect)" });
                continue;
            }
            if (i >= s.len) {
                cl.* = try cell(arena, null, w, .plain);
                continue;
            }
            const ep = c.list(d)[s.start + i];
            const look: Look = if (focused) .{ .letter = picker.letter(i) } else if (c.pick == ep) .selected else .dim;
            cl.* = try cell(arena, c.graph.endpoints[ep], w, look);
        }
        try lines.append(arena, try row(arena, size.cols, cells[0], cells[1]));
    }
    try lines.append(arena, "");
    const n = c.graph.connections.len;
    try lines.append(arena, try std.fmt.allocPrint(arena, "  " ++ style.dim ++ "{s}" ++ style.off, .{switch (n) {
        0 => "no connections",
        1 => "1 connection",
        else => try std.fmt.allocPrint(arena, "{d} connections", .{n}),
    }}));

    return frame(arena, .{
        .title = try title(arena, c.profile, c.modified, size.cols),
        .body = lines.items,
        .scroll = 0,
        .menu = try connectMenu(arena, c, focused_pages.count() > 1),
        .status = c.status,
    }, size);
}

fn connectMenu(arena: Allocator, c: Connect, paged: bool) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (c.pick) |p| {
        const label = c.graph.endpoints[p].label;
        if (c.graph.endpoints[p].direction == .from)
            try w.print("Connect {s} → pick where it goes   ", .{label})
        else
            try w.print("Connect → {s}: pick what feeds it   ", .{label});
    } else {
        try w.writeAll("Connect: pick a device   " ++ style.bold ++ "Tab" ++ style.off ++ " Other column   ");
    }
    if (paged) try w.writeAll(style.bold ++ "PgUp/PgDn" ++ style.off ++ " Page   ");
    try w.writeAll(style.bold ++ "Esc" ++ style.off ++ " Back");
    return out.toOwnedSlice();
}

/// Picking a Connection to undo: the CONNECTIONS list with letters, in
/// place of the columns, as in the script.
pub const Disconnect = struct {
    graph: graph.Graph,
    profile: []const u8,
    modified: bool,
    status: Status = .{},
    /// The list's page.
    page: usize = 0,
};

/// Rows the Connections get on the Disconnect screen: the body less the header.
pub fn disconnectRows(size: Size) usize {
    return bodyRows(size) -| 1;
}

/// The Disconnect screen, one string per row.
pub fn disconnect(arena: Allocator, d: Disconnect, size: Size) Error![]const []const u8 {
    const g = d.graph;
    const pages: picker.Pages = .init(g.connections.len, disconnectRows(size));
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(arena, if (pages.count() > 1)
        try std.fmt.allocPrint(arena, style.bold ++ "  CONNECTIONS  {d}/{d}" ++ style.off, .{ pages.clamp(d.page) + 1, pages.count() })
    else
        style.bold ++ "  CONNECTIONS" ++ style.off);
    if (g.connections.len == 0) try lines.append(arena, dimLine("(no connections)"));
    const shown = pages.slice(d.page);
    for (g.connections[shown.start..][0..shown.len], 0..) |c, i| {
        try lines.append(arena, try connectionLine(arena, g, c, size.cols, picker.letter(i)));
    }
    return frame(arena, .{
        .title = try title(arena, d.profile, d.modified, size.cols),
        .body = lines.items,
        .scroll = 0,
        .menu = if (pages.count() > 1)
            "Disconnect: pick a connection   " ++ style.bold ++ "PgUp/PgDn" ++ style.off ++ " Page   " ++ style.bold ++ "Esc" ++ style.off ++ " Back"
        else
            "Disconnect: pick a connection   " ++ style.bold ++ "Esc" ++ style.off ++ " Back",
        .status = d.status,
    }, size);
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

/// How a column cell is drawn.
const Look = union(enum) {
    /// `  ● label`, as on the home screen.
    plain,
    /// `x ● label`, the letter that picks it in bold cyan.
    letter: u8,
    /// `  ● label`, dimmed: not in the focused column.
    dim,
    /// `  ● label` in reverse video: the first pick.
    selected,
    /// Dimmed text in place of an Endpoint.
    note: []const u8,
};

/// One column cell, `  ● label`, exactly `w` columns wide; blank for none.
fn cell(arena: Allocator, ep: ?graph.Endpoint, w: usize, look: Look) Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    var l: text.Line = .init(&out.writer, w);
    if (look == .note) {
        try l.text("  " ++ style.dim);
        try l.text(look.note);
        try l.text(style.off);
    }
    if (ep) |e| {
        switch (look) {
            .letter => |c| {
                try l.text(style.bold ++ style.cyan);
                try l.text(&.{c});
                try l.text(style.off ++ " ");
            },
            .dim => try l.text("  " ++ style.dim),
            .selected => try l.text("  " ++ style.reverse),
            .plain, .note => try l.text("  "),
        }
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
    for (g.connections) |c| try lines.append(arena, try connectionLine(arena, g, c, cols, null));
    return lines.items;
}

/// `  ● source → destination`, coloured by the Source's Kind; with a letter,
/// `x ● …`, the letter in bold cyan.
fn connectionLine(arena: Allocator, g: graph.Graph, c: graph.Connection, cols: usize, letter: ?u8) Error![]const u8 {
    // As in the script: the Source padded to `w`, the Destination cut to it.
    const w = (cols -| 10) / 2;
    const col = style.kind(g.endpoints[c.from].kind);
    var from: Writer.Allocating = .init(arena);
    try text.fit(&from.writer, g.endpoints[c.from].label, w);
    var out: Writer.Allocating = .init(arena);
    var l: text.Line = .init(&out.writer, cols);
    if (letter) |x| {
        try l.text(style.bold ++ style.cyan);
        try l.text(&.{x});
        try l.text(style.off ++ " ");
    } else {
        try l.text("  ");
    }
    try l.text(col);
    try l.text("● ");
    try l.text(from.written());
    try l.text(style.off ++ " → ");
    try l.text(col);
    try l.text(try cut(arena, g.endpoints[c.to].label, w));
    try l.text(style.off);
    return out.toOwnedSlice();
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

fn connectRows(arena: Allocator, c: Connect, size: Size) ![]const []const u8 {
    return connect(arena, c, size);
}

test "connect: letters in the focused column only, the other dimmed, Connections summed up" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // FROM lists only what can be picked: USB Video, not WORLDE.
    const c: Connect = .{ .graph = fixture, .profile = "default", .modified = false, .focus = .from, .from = &.{0}, .to = try column(arena, fixture, .to) };
    const rows = try connectRows(arena, c, .{ .rows = 14, .cols = 50 });
    try testing.expectEqual(14, rows.len);
    try expectRows(&.{
        "aroute  profile: default   ● audio  ● MIDI",
        try dashes(arena, 50),
        "  FROM                  │   TO                   ",
        "a ● USB Video Analog S… │   ● Speakers           ",
        "                        │   ● 日本語のスピーカー ",
        "                        │   ● Clipper MIDI 2     ",
        "",
        "  3 connections",
        "",
        "",
        "",
        try dashes(arena, 50),
        "Connect: pick a device   Tab Other column   Esc B…",
        "",
    }, try plainRows(arena, rows));
    try testing.expect(std.mem.startsWith(u8, rows[3], style.bold ++ style.cyan ++ "a" ++ style.off ++ " " ++ style.audio ++ "● USB"));
    try testing.expect(std.mem.find(u8, rows[3], style.dim ++ style.audio ++ "● Speakers") != null);
    try testing.expect(std.mem.find(u8, rows[5], style.dim ++ style.midi ++ "● Clipper") != null);
}

test "connect: the first pick in reverse video, on its page of the other column" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c: Connect = .{ .graph = fixture, .profile = "default", .modified = false, .focus = .from, .from = &.{0}, .to = try column(arena, fixture, .to), .pick = 3 };
    // 2 rows for the columns: Clipper MIDI 2 is on the TO column's second page.
    const size: Size = .{ .rows = 10, .cols = 50 };
    try testing.expectEqual(2, pickRows(size));
    const rows = try connectRows(arena, c, size);
    const p = try plainRows(arena, rows);
    try expectRows(&.{
        "  FROM                  │   TO                   ",
        "a ● USB Video Analog S… │   ● Clipper MIDI 2     ",
        "",
        "  3 connections",
    }, p[2..6]);
    try testing.expect(std.mem.find(u8, rows[3], style.reverse ++ style.midi ++ "● Clipper") != null);
    try testing.expectEqualStrings("Connect → Clipper MIDI 2: pick what feeds it   Es…", p[8]);

    const from: Connect = .{ .graph = fixture, .profile = "default", .modified = false, .focus = .to, .from = try column(arena, fixture, .from), .to = &.{ 1, 5 }, .pick = 0 };
    const wide = try plainRows(arena, try connectRows(arena, from, .{ .rows = 10, .cols = 90 }));
    try testing.expectEqualStrings("Connect USB Video Analog Stereo → pick where it goes   Esc Back", wide[8]);
}

test "connect: more than a page shows which page, and PgUp/PgDn in the menu" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var eps: [7]graph.Endpoint = undefined;
    for (&eps, 0..) |*ep, i| ep.* = .{ .label = try std.fmt.allocPrint(arena, "Out {d}", .{i}), .kind = .audio, .direction = .to, .ports = .{ .pw = &.{} } };
    const g: graph.Graph = .{ .endpoints = &eps, .connections = &.{} };
    const size: Size = .{ .rows = 11, .cols = 70 };
    try testing.expectEqual(3, pickRows(size));
    const all = try column(arena, g, .to);

    var c: Connect = .{ .graph = g, .profile = "default", .modified = false, .focus = .to, .from = &.{}, .to = all, .page = 1 };
    var p = try plainRows(arena, try connectRows(arena, c, size));
    try expectRows(&.{
        "  FROM                            │   TO  2/3                        ",
        "                                  │ a ● Out 3                        ",
        "                                  │ b ● Out 4                        ",
        "                                  │ c ● Out 5                        ",
        "",
        "  no connections",
        try dashes(arena, 70),
        "Connect: pick a device   Tab Other column   PgUp/PgDn Page   Esc Back",
    }, p[2..10]);

    // The last page is short; a page past it is the last one.
    c.page = 9;
    p = try plainRows(arena, try connectRows(arena, c, size));
    try expectRows(&.{
        "  FROM                            │   TO  3/3                        ",
        "                                  │ a ● Out 6                        ",
        "",
        "  no connections",
    }, p[2..6]);

    // The unfocused column has no page indicator.
    c = .{ .graph = g, .profile = "default", .modified = false, .focus = .from, .from = &.{}, .to = all };
    p = try plainRows(arena, try connectRows(arena, c, size));
    try expectRows(&.{
        "  FROM                            │   TO                             ",
        "  (nothing to connect)            │   ● Out 0                        ",
        "                                  │   ● Out 1                        ",
        "                                  │   ● Out 2                        ",
        "",
        "  no connections",
    }, p[2..8]);
    try testing.expectEqualStrings("Connect: pick a device   Tab Other column   Esc Back", p[9]);
}

test "connect: one connection; a tiny terminal shows what fits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var g = fixture;
    g.connections = fixture.connections[0..1];
    const c: Connect = .{ .graph = g, .profile = "default", .modified = true, .focus = .from, .from = &.{ 0, 2 }, .to = try column(arena, g, .to), .page = 3, .pick = null };
    const p = try plainRows(arena, try connectRows(arena, c, .{ .rows = 24, .cols = 80 }));
    try testing.expectEqualStrings("  1 connection", p[7]);

    for ([_]Size{
        .{ .rows = 0, .cols = 0 },  .{ .rows = 1, .cols = 1 }, .{ .rows = 3, .cols = 5 },  .{ .rows = 6, .cols = 2 },
        .{ .rows = 7, .cols = 12 }, .{ .rows = 8, .cols = 3 }, .{ .rows = 9, .cols = 20 }, .{ .rows = 10, .cols = 4 },
    }) |size| {
        const rows = try connectRows(arena, c, size);
        try testing.expectEqual(size.rows, rows.len);
        for (rows) |r| try testing.expect(text.width(r) <= size.cols);
    }
}

test "disconnect: the Connections with letters, in place of the columns" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d: Disconnect = .{ .graph = fixture, .profile = "default", .modified = true, .status = .{ .text = "✓ earlier" } };
    const rows = try disconnect(arena, d, .{ .rows = 12, .cols = 50 });
    try expectRows(&.{
        "aroute  profile: default (modified)   ● audio  ● …",
        try dashes(arena, 50),
        "  CONNECTIONS",
        "a ● USB Video Analog St… → Speakers",
        "b ● WORLDE               → 日本語のスピーカー",
        "c ● Speakers · monitor   → Clipper MIDI 2",
        "",
        "",
        "",
        try dashes(arena, 50),
        "Disconnect: pick a connection   Esc Back",
        "✓ earlier",
    }, try plainRows(arena, rows));
    try testing.expect(std.mem.startsWith(u8, rows[3], style.bold ++ style.cyan ++ "a" ++ style.off ++ " " ++ style.audio ++ "● USB"));
    try testing.expect(std.mem.startsWith(u8, rows[4], style.bold ++ style.cyan ++ "b" ++ style.off ++ " " ++ style.midi ++ "● WORLDE"));

    const none: Disconnect = .{ .graph = .{ .endpoints = &.{}, .connections = &.{} }, .profile = "default", .modified = false };
    const p = try plainRows(arena, try disconnect(arena, none, .{ .rows = 12, .cols = 50 }));
    try expectRows(&.{ "  CONNECTIONS", "  (no connections)", "" }, p[2..5]);
}

test "disconnect: more than a page shows which page, letters from `a` on each" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var g = fixture;
    var conns: [7]graph.Connection = undefined;
    for (&conns, 0..) |*c, i| c.* = fixture.connections[i % 3];
    g.connections = &conns;
    // 3 rows for the Connections.
    const size: Size = .{ .rows = 9, .cols = 70 };
    try testing.expectEqual(3, disconnectRows(size));

    var d: Disconnect = .{ .graph = g, .profile = "default", .modified = false, .page = 1 };
    var p = try plainRows(arena, try disconnect(arena, d, size));
    try expectRows(&.{
        "  CONNECTIONS  2/3",
        "a ● USB Video Analog Stereo        → Speakers",
        "b ● WORLDE                         → 日本語のスピーカー",
        "c ● Speakers · monitor             → Clipper MIDI 2",
        try dashes(arena, 70),
        "Disconnect: pick a connection   PgUp/PgDn Page   Esc Back",
    }, p[2..8]);

    // The last page is short; a page past it is the last one.
    d.page = 9;
    p = try plainRows(arena, try disconnect(arena, d, size));
    try expectRows(&.{ "  CONNECTIONS  3/3", "a ● USB Video Analog Stereo        → Speakers", "", "" }, p[2..6]);
}

test "disconnect: a tiny terminal shows what fits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]Size{
        .{ .rows = 0, .cols = 0 },  .{ .rows = 1, .cols = 1 }, .{ .rows = 3, .cols = 5 },  .{ .rows = 6, .cols = 2 },
        .{ .rows = 7, .cols = 12 }, .{ .rows = 8, .cols = 3 }, .{ .rows = 9, .cols = 20 }, .{ .rows = 10, .cols = 4 },
    }) |size| {
        for ([_]usize{ 0, 1, 5 }) |page| {
            const rows = try disconnect(arena, .{ .graph = fixture, .profile = "default", .modified = true, .page = page }, size);
            try testing.expectEqual(size.rows, rows.len);
            for (rows) |r| try testing.expect(text.width(r) <= size.cols);
        }
    }
}
