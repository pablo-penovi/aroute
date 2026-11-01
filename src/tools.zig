//! Runs the PipeWire and ALSA command-line tools (ADR 0001), to read the graph
//! and to change it. Nothing here interprets what they list; see
//! `pipewire.zig` and `alsa.zig` for that.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const graph = @import("graph.zig");

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

/// Makes a Link with `pw-link` or `aconnect`. One that already exists counts as made.
pub fn connect(gpa: Allocator, io: Io, ends: graph.Ends) Error!void {
    var buf: [2][16]u8 = undefined;
    return switch (ends) {
        .pw => |p| change(gpa, io, &.{ "pw-link", id(&buf[0], p[0]), id(&buf[1], p[1]) }, "File exists"),
        .alsa => |a| change(gpa, io, &.{ "aconnect", addr(&buf[0], a[0]), addr(&buf[1], a[1]) }, "already subscribed"),
    };
}

/// Undoes a Link with `pw-link -d` or `aconnect -d`.
pub fn disconnect(gpa: Allocator, io: Io, ends: graph.Ends) Error!void {
    var buf: [2][16]u8 = undefined;
    return switch (ends) {
        .pw => |p| change(gpa, io, &.{ "pw-link", "-d", id(&buf[0], p[0]), id(&buf[1], p[1]) }, null),
        .alsa => |a| change(gpa, io, &.{ "aconnect", "-d", addr(&buf[0], a[0]), addr(&buf[1], a[1]) }, null),
    };
}

fn id(buf: *[16]u8, n: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

fn addr(buf: *[16]u8, a: graph.Addr) []const u8 {
    return std.fmt.bufPrint(buf, "{f}", .{a}) catch unreachable;
}

/// Succeeds if the command does, or if its output says it was already done.
fn change(gpa: Allocator, io: Io, argv: []const []const u8, already: ?[]const u8) Error!void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.MissingTool,
        else => return error.ToolFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term.success()) return;
    const done = already orelse return error.ToolFailed;
    if (std.mem.find(u8, result.stderr, done) == null and std.mem.find(u8, result.stdout, done) == null) return error.ToolFailed;
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
