const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cli = @import("cli.zig");
const graph = @import("graph.zig");
const pipewire = @import("pipewire.zig");
const alsa = @import("alsa.zig");
const tools = @import("tools.zig");
const profile = @import("profile.zig");
const Aliases = @import("aliases.zig").Aliases;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const config_dir = try configDir(arena, init.environ_map.*);

    const profiles_dir = try std.fs.path.join(arena, &.{ config_dir, "profiles" });
    const aliases = try readAliases(arena, io, config_dir);
    const show_all = showAll(init.environ_map.*);

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    const command: []const u8 = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, command, "--list")) {
        try cli.list(out, arena, try scan(arena, io, aliases, show_all));
    } else if (std.mem.eql(u8, command, "--profiles")) {
        for (try profileNames(arena, io, profiles_dir)) |name| try out.print("{s}\n", .{name});
    } else if (std.mem.eql(u8, command, "--save")) {
        const name: []const u8 = if (args.len > 2) args[2] else "";
        if (name.len == 0) die(io, "usage: aroute --save NAME", .{});
        if (!profile.validName(name)) die(io, profile.invalid_name, .{});
        const g = try scan(arena, io, aliases, show_all);
        const path = try save(arena, io, profiles_dir, name, g, aliases);
        try out.print("Saved {s}\n", .{path});
    } else if (command.len == 0) {
        die(io, "not implemented yet (see docs/design.md)", .{});
    } else {
        die(io, "unknown option '{s}' (try --help)", .{command});
    }
    try out.flush();
}

/// Writes every current Link as the Profile `name`, overwriting it, and
/// returns its path.
fn save(arena: Allocator, io: Io, profiles_dir: []const u8, name: []const u8, g: graph.Graph, aliases: Aliases) ![]const u8 {
    var file: Io.Writer.Allocating = .init(arena);
    try profile.write(&file.writer, arena, name, try savedAt(arena, io), g, aliases);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.conf", .{ profiles_dir, name });
    Io.Dir.cwd().createDirPath(io, profiles_dir) catch die(io, "could not write {s}", .{path});
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file.written() }) catch die(io, "could not write {s}", .{path});
    return path;
}

/// Local time as the script writes it (`date '+%F %T'`); empty, as in the
/// script, if `date` fails.
fn savedAt(arena: Allocator, io: Io) Allocator.Error![]const u8 {
    const now = tools.localTime(arena, io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "",
    };
    return std.mem.trimEnd(u8, now, "\n");
}

/// No profiles directory, or an unreadable one, means no Profiles.
fn profileNames(arena: Allocator, io: Io, profiles_dir: []const u8) Allocator.Error![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, profiles_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    return profile.names(arena, io, dir) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => &.{},
    };
}

/// Reads the graph, with aliases applied to every Endpoint label.
fn scan(arena: Allocator, io: Io, aliases: Aliases, show_all: bool) !graph.Graph {
    const dump = tools.pwDump(arena, io) catch |err| switch (err) {
        error.MissingTool => die(io, "missing dependency: pw-dump", .{}),
        error.ToolFailed => die(io, "cannot read the PipeWire graph (is PipeWire running?)", .{}),
        else => |e| return e,
    };
    const midi = try alsa.parse(arena, .{
        .sources = try aconnect(arena, io, .sources),
        .destinations = try aconnect(arena, io, .destinations),
        .connections = try aconnect(arena, io, .connections),
    }, show_all);
    var g = pipewire.parse(arena, dump, midi) catch |err| switch (err) {
        error.InvalidDump => die(io, "cannot read the PipeWire graph (is PipeWire running?)", .{}),
        else => |e| return e,
    };
    try g.applyAliases(arena, aliases);
    return g;
}

/// Like the script, a failing `aconnect` (e.g. no ALSA sequencer) just means no ALSA MIDI.
fn aconnect(arena: Allocator, io: Io, list: tools.AconnectList) Allocator.Error![]const u8 {
    return tools.aconnect(arena, io, list) catch |err| switch (err) {
        error.MissingTool => die(io, "missing dependency: aconnect", .{}),
        error.ToolFailed => "",
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// `AROUTE_SHOW_ALL=1` also lists the normally hidden Midi Through clients and Sync ports.
fn showAll(env: std.process.Environ.Map) bool {
    return std.mem.eql(u8, env.get("AROUTE_SHOW_ALL") orelse "", "1");
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

test "AROUTE_SHOW_ALL is on only when it is 1" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!showAll(env));
    try env.put("AROUTE_SHOW_ALL", "0");
    try std.testing.expect(!showAll(env));
    try env.put("AROUTE_SHOW_ALL", "yes");
    try std.testing.expect(!showAll(env));
    try env.put("AROUTE_SHOW_ALL", "1");
    try std.testing.expect(showAll(env));
}
