//! Runs the PipeWire command-line tools (ADR 0001), to read the graph and to
//! change it. Nothing here interprets what they list; see `pipewire.zig` for
//! that. ALSA goes through the sequencer directly (`seq.zig`, ADR 0002).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The tools aroute runs, checked for at startup.
pub const Tool = enum {
    @"pw-dump",
    @"pw-link",

    /// Both come with PipeWire.
    const install = "pipewire (Arch), pipewire-bin (Debian, Ubuntu) or pipewire-utils (Fedora)";
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

/// What is missing and what to install for it, as
///
///     missing dependency: pw-link
///       pw-dump and pw-link come with PipeWire: install pipewire (Arch), …
pub fn explainMissing(w: *Io.Writer, tools: []const Tool) Io.Writer.Error!void {
    try w.print("missing {s}: ", .{if (tools.len == 1) "dependency" else "dependencies"});
    for (tools, 0..) |t, i| try w.print("{s}{t}", .{ if (i > 0) ", " else "", t });
    try w.writeAll("\n  pw-dump and pw-link come with PipeWire: install " ++ Tool.install ++ "\n");
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

/// The local time as `date '+%F %T'` prints it (`2026-11-01 16:45:00`),
/// newline included. Caller owns the result.
pub fn localTime(gpa: Allocator, io: Io) Error![]u8 {
    return run(gpa, io, &.{ "date", "+%F %T" });
}

/// Makes a PipeWire Link with `pw-link`. One that already exists counts as
/// made. On `error.ToolFailed`, `why` (if given) is set to what `pw-link`
/// said, on one line, allocated with `gpa`.
pub fn connect(gpa: Allocator, io: Io, ports: [2]u32, why: ?*[]const u8) Error!void {
    var buf: [2][16]u8 = undefined;
    return change(gpa, io, &.{ "pw-link", id(&buf[0], ports[0]), id(&buf[1], ports[1]) }, "File exists", why);
}

/// Undoes a PipeWire Link with `pw-link -d`.
pub fn disconnect(gpa: Allocator, io: Io, ports: [2]u32) Error!void {
    var buf: [2][16]u8 = undefined;
    return change(gpa, io, &.{ "pw-link", "-d", id(&buf[0], ports[0]), id(&buf[1], ports[1]) }, null, null);
}

fn id(buf: *[16]u8, n: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
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
    // Not executable.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/pw-link", .data = "" });

    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fmt.allocPrint(arena, "/nonexistent:{s}/a::{s}/b", .{ root, root });
    try testing.expectEqualSlices(Tool, &.{.@"pw-link"}, try missing(arena, testing.io, path));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/pw-link", .data = "", .flags = .{ .permissions = .executable_file } });
    try testing.expectEqualSlices(Tool, &.{}, try missing(arena, testing.io, path));
    try testing.expectEqualSlices(Tool, &.{ .@"pw-dump", .@"pw-link" }, try missing(arena, testing.io, ""));
}

test "oneLine: what a tool said, on one line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("failed to link ports: No such file or directory", try oneLine(arena, "pw-link", "failed to link ports: No such file or directory\n", ""));
    try testing.expectEqualStrings("Connection failed (Operation not permitted) try again", try oneLine(arena, "pw-link", "\nConnection failed (Operation not permitted)\ntry again\n", "ignored"));
    try testing.expectEqualStrings("on stdout", try oneLine(arena, "pw-link", " \n", "on stdout\n"));
    try testing.expectEqualStrings("pw-link failed", try oneLine(arena, "pw-link", "", "\n"));
}

test "explainMissing: what to install" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try explainMissing(&out.writer, &.{ .@"pw-dump", .@"pw-link" });
    try testing.expectEqualStrings(
        \\missing dependencies: pw-dump, pw-link
        \\  pw-dump and pw-link come with PipeWire: install pipewire (Arch), pipewire-bin (Debian, Ubuntu) or pipewire-utils (Fedora)
        \\
    , out.written());

    out.clearRetainingCapacity();
    try explainMissing(&out.writer, &.{.@"pw-link"});
    try testing.expectEqualStrings("missing dependency: pw-link\n  pw-dump and pw-link come with PipeWire: install pipewire (Arch), pipewire-bin (Debian, Ubuntu) or pipewire-utils (Fedora)\n", out.written());
}
