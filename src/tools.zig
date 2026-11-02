//! Runs the PipeWire and ALSA command-line tools (ADR 0001), to read the graph
//! and to change it. Nothing here interprets what they list; see
//! `pipewire.zig` and `alsa.zig` for that.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const graph = @import("graph.zig");

/// The tools aroute runs, checked for at startup.
pub const Tool = enum {
    @"pw-dump",
    @"pw-link",
    aconnect,

    /// Where it comes from, and what to install to get it.
    const Source = struct { from: []const u8, install: []const u8 };

    const sources = [_]struct { tools: []const Tool, source: Source }{
        .{ .tools = &.{ .@"pw-dump", .@"pw-link" }, .source = .{
            .from = "PipeWire",
            .install = "pipewire (Arch), pipewire-bin (Debian, Ubuntu) or pipewire-utils (Fedora)",
        } },
        .{ .tools = &.{.aconnect}, .source = .{ .from = "ALSA", .install = "alsa-utils" } },
    };
};

/// The tools not found as executables in the directories of `path` (a
/// `$PATH` value, where an empty entry is the current directory).
pub fn missing(arena: Allocator, io: Io, path: []const u8) Allocator.Error![]const Tool {
    var list: std.ArrayList(Tool) = .empty;
    for (std.enums.values(Tool)) |tool| {
        var dirs = std.mem.splitScalar(u8, path, ':');
        const found = while (dirs.next()) |dir| {
            const file = try std.fs.path.join(arena, &.{ if (dir.len == 0) "." else dir, @tagName(tool) });
            if (Io.Dir.cwd().access(io, file, .{ .execute = true })) |_| break true else |_| {}
        } else false;
        if (!found) try list.append(arena, tool);
    }
    return list.items;
}

/// What is missing and what to install for it, one line each, as
///
///     missing dependencies: pw-link, aconnect
///       pw-dump and pw-link come with PipeWire: install pipewire (Arch), …
///       aconnect comes with ALSA: install alsa-utils
pub fn explainMissing(w: *Io.Writer, tools: []const Tool) Io.Writer.Error!void {
    try w.print("missing {s}: ", .{if (tools.len == 1) "dependency" else "dependencies"});
    for (tools, 0..) |t, i| try w.print("{s}{t}", .{ if (i > 0) ", " else "", t });
    try w.writeByte('\n');
    for (Tool.sources) |s| {
        for (s.tools) |t| {
            if (std.mem.findScalar(Tool, tools, t) != null) break;
        } else continue;
        try w.writeAll("  ");
        for (s.tools, 0..) |t, i| try w.print("{s}{t}", .{ if (i == 0) "" else if (i + 1 == s.tools.len) " and " else ", ", t });
        try w.print(" come{s} with {s}: install {s}\n", .{ if (s.tools.len == 1) "s" else "", s.source.from, s.source.install });
    }
}

pub const Error = error{
    /// The tool is not installed (not on PATH).
    MissingTool,
    /// It ran but failed, e.g. PipeWire is not running.
    ToolFailed,
} || Allocator.Error;

/// The whole PipeWire graph as JSON. Caller owns the result.
pub fn pwDump(gpa: Allocator, io: Io) Error![]u8 {
    return run(gpa, io, &.{"pw-dump"});
}

pub const AconnectList = enum {
    /// `-i`: readable Ports.
    sources,
    /// `-o`: writable Ports.
    destinations,
    /// `-l`: every Port and its subscriptions.
    connections,
};

/// The ALSA sequencer Ports as `aconnect` lists them. Caller owns the result.
pub fn aconnect(gpa: Allocator, io: Io, list: AconnectList) Error![]u8 {
    return run(gpa, io, &.{ "aconnect", switch (list) {
        .sources => "-i",
        .destinations => "-o",
        .connections => "-l",
    } });
}

/// The local time as `date '+%F %T'` prints it (`2026-11-01 16:45:00`),
/// newline included. Caller owns the result.
pub fn localTime(gpa: Allocator, io: Io) Error![]u8 {
    return run(gpa, io, &.{ "date", "+%F %T" });
}

/// Makes a Link with `pw-link` or `aconnect`. One that already exists counts
/// as made. On `error.ToolFailed`, `why` (if given) is set to what the tool
/// said, on one line, allocated with `gpa`.
pub fn connect(gpa: Allocator, io: Io, ends: graph.Ends, why: ?*[]const u8) Error!void {
    var buf: [2][16]u8 = undefined;
    return switch (ends) {
        .pw => |p| change(gpa, io, &.{ "pw-link", id(&buf[0], p[0]), id(&buf[1], p[1]) }, "File exists", why),
        .alsa => |a| change(gpa, io, &.{ "aconnect", addr(&buf[0], a[0]), addr(&buf[1], a[1]) }, "already subscribed", why),
    };
}

/// Undoes a Link with `pw-link -d` or `aconnect -d`.
pub fn disconnect(gpa: Allocator, io: Io, ends: graph.Ends) Error!void {
    var buf: [2][16]u8 = undefined;
    return switch (ends) {
        .pw => |p| change(gpa, io, &.{ "pw-link", "-d", id(&buf[0], p[0]), id(&buf[1], p[1]) }, null, null),
        .alsa => |a| change(gpa, io, &.{ "aconnect", "-d", addr(&buf[0], a[0]), addr(&buf[1], a[1]) }, null, null),
    };
}

fn id(buf: *[16]u8, n: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

fn addr(buf: *[16]u8, a: graph.Addr) []const u8 {
    return std.fmt.bufPrint(buf, "{f}", .{a}) catch unreachable;
}

/// Succeeds if the command does, or if its output says it was already done.
/// Otherwise, sets `why` to what it said (see `oneLine`).
fn change(gpa: Allocator, io: Io, argv: []const []const u8, already: ?[]const u8, why: ?*[]const u8) Error!void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.MissingTool,
        else => {
            if (why) |w| w.* = try std.fmt.allocPrint(gpa, "{s} failed", .{argv[0]});
            return error.ToolFailed;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term.success()) return;
    if (already) |done| {
        if (std.mem.find(u8, result.stderr, done) != null or std.mem.find(u8, result.stdout, done) != null) return;
    }
    if (why) |w| w.* = try oneLine(gpa, argv[0], result.stderr, result.stdout);
    return error.ToolFailed;
}

/// A tool's error output on one line, as the script shows it: `stderr`, or
/// `stdout` if that is empty, with its lines joined by spaces; `<tool>
/// failed` if it said nothing.
fn oneLine(gpa: Allocator, tool: []const u8, stderr: []const u8, stdout: []const u8) Allocator.Error![]const u8 {
    const said = std.mem.trim(u8, if (std.mem.trim(u8, stderr, &std.ascii.whitespace).len > 0) stderr else stdout, &std.ascii.whitespace);
    if (said.len == 0) return std.fmt.allocPrint(gpa, "{s} failed", .{tool});
    const line = try gpa.dupe(u8, said);
    std.mem.replaceScalar(u8, line, '\n', ' ');
    return line;
}

fn run(gpa: Allocator, io: Io, argv: []const []const u8) Error![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.MissingTool,
        else => return error.ToolFailed,
    };
    gpa.free(result.stderr);
    if (!result.term.success()) {
        gpa.free(result.stdout);
        return error.ToolFailed;
    }
    return result.stdout;
}

const testing = std.testing;

test "missing: executables on PATH, empty entries meaning the current directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/pw-dump", .data = "", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/pw-link", .data = "", .flags = .{ .permissions = .executable_file } });
    // Not executable.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/aconnect", .data = "" });

    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fmt.allocPrint(arena, "/nonexistent:{s}/a::{s}/b", .{ root, root });
    try testing.expectEqualSlices(Tool, &.{.aconnect}, try missing(arena, testing.io, path));
    try testing.expectEqualSlices(Tool, &.{ .@"pw-dump", .@"pw-link", .aconnect }, try missing(arena, testing.io, ""));
}

test "oneLine: what a tool said, on one line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("failed to link ports: No such file or directory", try oneLine(arena, "pw-link", "failed to link ports: No such file or directory\n", ""));
    try testing.expectEqualStrings("Connection failed (Operation not permitted) try again", try oneLine(arena, "aconnect", "\nConnection failed (Operation not permitted)\ntry again\n", "ignored"));
    try testing.expectEqualStrings("on stdout", try oneLine(arena, "pw-link", " \n", "on stdout\n"));
    try testing.expectEqualStrings("pw-link failed", try oneLine(arena, "pw-link", "", "\n"));
}

test "explainMissing: what to install for each" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try explainMissing(&out.writer, &.{ .@"pw-link", .aconnect });
    try testing.expectEqualStrings(
        \\missing dependencies: pw-link, aconnect
        \\  pw-dump and pw-link come with PipeWire: install pipewire (Arch), pipewire-bin (Debian, Ubuntu) or pipewire-utils (Fedora)
        \\  aconnect comes with ALSA: install alsa-utils
        \\
    , out.written());

    out.clearRetainingCapacity();
    try explainMissing(&out.writer, &.{.aconnect});
    try testing.expectEqualStrings("missing dependency: aconnect\n  aconnect comes with ALSA: install alsa-utils\n", out.written());
}
