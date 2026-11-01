//! Runs the PipeWire and ALSA command-line tools (ADR 0001). Nothing here
//! interprets their output; see `pipewire.zig` and `alsa.zig` for that.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

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
