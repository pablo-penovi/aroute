const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cli = @import("cli.zig");
const graph = @import("graph.zig");
const pipewire = @import("pipewire.zig");
const tools = @import("tools.zig");
const Aliases = @import("aliases.zig").Aliases;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const config_dir = try configDir(arena, init.environ_map.*);

    const command: []const u8 = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, command, "--list")) {
        const g = try scan(arena, io, config_dir);
        var buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writer(io, &buf);
        try cli.list(&stdout.interface, arena, g);
        try stdout.interface.flush();
    } else if (command.len == 0) {
        die(io, "not implemented yet (see docs/design.md)", .{});
    } else {
        die(io, "unknown option '{s}' (try --help)", .{command});
    }
}

/// Reads the graph, with aliases applied to every label.
fn scan(arena: Allocator, io: Io, config_dir: []const u8) !graph.Graph {
    const dump = tools.pwDump(arena, io) catch |err| switch (err) {
        error.MissingTool => die(io, "missing dependency: pw-dump", .{}),
        error.ToolFailed => die(io, "cannot read the PipeWire graph (is PipeWire running?)", .{}),
        else => |e| return e,
    };
    var g = pipewire.parse(arena, dump) catch |err| switch (err) {
        error.InvalidDump => die(io, "cannot read the PipeWire graph (is PipeWire running?)", .{}),
        else => |e| return e,
    };
    try g.applyAliases(arena, try readAliases(arena, io, config_dir));
    return g;
}

/// A missing or unreadable aliases file means no aliases.
fn readAliases(arena: Allocator, io: Io, config_dir: []const u8) Allocator.Error!Aliases {
    const path = try std.fs.path.join(arena, &.{ config_dir, "aliases" });
    const source = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    return Aliases.parse(arena, source);
}

/// `${XDG_CONFIG_HOME:-$HOME/.config}/aroute`
fn configDir(arena: Allocator, env: std.process.Environ.Map) Allocator.Error![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(arena, &.{ xdg, "aroute" });
    }
    return std.fs.path.join(arena, &.{ env.get("HOME") orelse "", ".config", "aroute" });
}

fn die(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    stderr.interface.print("aroute: " ++ fmt ++ "\n", args) catch {};
    stderr.interface.flush() catch {};
    std.process.exit(1);
}

test "config dir follows XDG_CONFIG_HOME, falling back to ~/.config" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/home/u/.config/aroute", try configDir(arena, env));
    try env.put("XDG_CONFIG_HOME", "");
    try std.testing.expectEqualStrings("/home/u/.config/aroute", try configDir(arena, env));
    try env.put("XDG_CONFIG_HOME", "/xdg");
    try std.testing.expectEqualStrings("/xdg/aroute", try configDir(arena, env));
}
