const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cli = @import("cli.zig");
const graph = @import("graph.zig");
const pipewire = @import("pipewire.zig");
const alsa = @import("alsa.zig");
const seq = @import("seq.zig");
const tools = @import("tools.zig");
const profile = @import("profile.zig");
const load = @import("load.zig");
const term = @import("term.zig");
const tui = @import("tui.zig");
const Aliases = @import("aliases.zig").Aliases;

/// A panic in the TUI puts the terminal back first, so the trace is readable.
pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        term.restore();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    // As in the script, every command needs every tool.
    const missing = try tools.missing(arena, io, init.environ_map.get("PATH") orelse "");
    if (missing.len > 0) dieMissing(io, missing);
    const config_dir = try configDir(arena, init.environ_map.*);

    const aliases = try readAliases(arena, io, config_dir);
    const store: profile.Store = .{
        .io = io,
        .dir = try std.fs.path.join(arena, &.{ config_dir, "profiles" }),
        .aliases = aliases,
        .clock = savedAt,
    };
    const show_all = showAll(init.environ_map.*);
    // No sequencer (no `/dev/snd/seq`, or no permission) just means no ALSA MIDI.
    const sequencer: ?seq.Seq = seq.Seq.open("aroute") catch null;
    defer if (sequencer) |s| s.close();
    const source: Source = .{ .io = io, .seq = sequencer, .aliases = aliases, .show_all = show_all };

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    const command: []const u8 = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, command, "--list")) {
        try cli.list(out, arena, try source.scan(arena));
    } else if (std.mem.eql(u8, command, "--profiles")) {
        for (try store.list(arena)) |name| try out.print("{s}\n", .{name});
    } else if (std.mem.eql(u8, command, "--save")) {
        const name: []const u8 = if (args.len > 2) args[2] else "";
        if (name.len == 0) die(io, "usage: aroute --save NAME", .{});
        if (!profile.validName(name)) die(io, profile.invalid_name, .{});
        const g = try source.scan(arena);
        const path = try store.path(arena, name);
        store.save(arena, name, g) catch |err| switch (err) {
            error.Unwritable => die(io, "could not write {s}", .{path}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try out.print("Saved {s}\n", .{path});
    } else if (std.mem.eql(u8, command, "--load")) {
        const name: []const u8 = if (args.len > 2) args[2] else "";
        if (name.len == 0) die(io, "usage: aroute --load NAME [--force]", .{});
        const flag: []const u8 = if (args.len > 3) args[3] else "";
        if (flag.len > 0 and !std.mem.eql(u8, flag, "--force")) die(io, "unknown option '{s}' (try --help)", .{flag});
        const g = try source.scan(arena);
        const saved = store.read(arena, name) catch |err| switch (err) {
            error.Unreadable => die(io, "no profile named '{s}'", .{name}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const p = try load.plan(arena, g, saved);
        if (p.missing_audio.len > 0) try confirmMissing(io, name, p.missing_audio, flag.len > 0);
        const result = try load.apply(arena, g, p, Wiring{ .arena = arena, .io = io, .seq = sequencer });
        try load.summary(out, name, p, result, .{});
        try out.writeByte('\n');
    } else if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try out.writeAll(cli.help);
    } else if (command.len == 0) {
        if (!try Io.File.stdin().isTty(io) or !try Io.File.stdout().isTty(io)) {
            die(io, "the TUI needs a terminal (see --help for non-interactive use)", .{});
        }
        tui.run(init.gpa, io, Scanner{ .source = source }, TuiWiring{ .io = io, .seq = sequencer }, store) catch |err| switch (err) {
            error.Unreadable => die(io, "cannot read the PipeWire graph (is PipeWire running?)", .{}),
            else => |e| return e,
        };
    } else {
        die(io, "unknown option '{s}' (try --help)", .{command});
    }
    try out.flush();
}

/// Lists the missing audio Devices on stderr. Unless `force`, asks whether to
/// load anyway on a terminal, and gives up otherwise.
fn confirmMissing(io: Io, name: []const u8, missing: []const []const u8, force: bool) !void {
    var buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    try w.print("aroute: these audio devices from '{s}' are not present:\n", .{name});
    for (missing) |m| try w.print("  {s}\n", .{m});
    try w.flush();
    if (force) return;
    if (!try Io.File.stdin().isTty(io)) die(io, "not loaded (use --force to hook up only the available connections)", .{});

    try w.writeAll("Continue and hook up only the available connections? [y/N] ");
    try w.flush();
    var in_buf: [256]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &in_buf);
    const line = (stdin.interface.takeDelimiter('\n') catch null) orelse "";
    // As bash's `read`, leading blanks are dropped.
    const answer = std.mem.trimStart(u8, line, " \t");
    if (answer.len == 0 or (answer[0] != 'y' and answer[0] != 'Y')) die(io, "not loaded", .{});
}

/// Changes the graph for `load.apply`.
const Wiring = struct {
    arena: Allocator,
    io: Io,
    seq: ?seq.Seq,

    pub fn connect(w: Wiring, ends: graph.Ends) error{ ToolFailed, OutOfMemory }!void {
        switch (ends) {
            .pw => |p| tools.connect(w.arena, w.io, p, null) catch |err| return w.fail(err),
            .alsa => |a| if (try alsaConnect(w.seq, w.arena, a) != null) return error.ToolFailed,
        }
    }

    pub fn disconnect(w: Wiring, ends: graph.Ends) error{ ToolFailed, OutOfMemory }!void {
        switch (ends) {
            .pw => |p| tools.disconnect(w.arena, w.io, p) catch |err| return w.fail(err),
            .alsa => |a| if (!alsaDisconnect(w.seq, a)) return error.ToolFailed,
        }
    }

    fn fail(w: Wiring, err: tools.Error) error{ ToolFailed, OutOfMemory } {
        return switch (err) {
            error.MissingTool => die(w.io, "missing dependency: pw-link", .{}),
            error.ToolFailed => error.ToolFailed,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
};

/// Changes the graph for the TUI.
const TuiWiring = struct {
    io: Io,
    seq: ?seq.Seq,

    /// Makes a Link; null if it was made, else what went wrong.
    pub fn connect(w: TuiWiring, arena: Allocator, ends: graph.Ends) Allocator.Error!?[]const u8 {
        const p = switch (ends) {
            .pw => |p| p,
            .alsa => |a| return alsaConnect(w.seq, arena, a),
        };
        var why: []const u8 = "";
        tools.connect(arena, w.io, p, &why) catch |err| switch (err) {
            error.MissingTool => die(w.io, "missing dependency: pw-link", .{}),
            error.ToolFailed => return why,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return null;
    }

    /// Undoes a Link; whether it did.
    pub fn disconnect(w: TuiWiring, arena: Allocator, ends: graph.Ends) Allocator.Error!bool {
        const p = switch (ends) {
            .pw => |p| p,
            .alsa => |a| return alsaDisconnect(w.seq, a),
        };
        tools.disconnect(arena, w.io, p) catch |err| switch (err) {
            error.MissingTool => die(w.io, "missing dependency: pw-link", .{}),
            error.ToolFailed => return false,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return true;
    }
};

/// Null if made, else why not. Without a sequencer there are no ALSA Ports
/// to wire; this says what `aconnect` said then.
fn alsaConnect(s: ?seq.Seq, arena: Allocator, a: [2]graph.Addr) Allocator.Error!?[]const u8 {
    const open = s orelse return "can't open sequencer";
    return open.connect(arena, a[0], a[1]);
}

fn alsaDisconnect(s: ?seq.Seq, a: [2]graph.Addr) bool {
    const open = s orelse return false;
    return open.disconnect(a[0], a[1]);
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

/// Where the graph is read from.
const Source = struct {
    io: Io,
    seq: ?seq.Seq,
    aliases: Aliases,
    show_all: bool,

    /// Reads the graph, with aliases applied to every Endpoint label.
    fn scan(s: Source, arena: Allocator) Allocator.Error!graph.Graph {
        return s.read(arena) catch |err| switch (err) {
            error.Unreadable => die(s.io, "cannot read the PipeWire graph (is PipeWire running?)", .{}),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// Like `scan`, but a graph that can't be read is an error.
    fn read(s: Source, arena: Allocator) tui.ScanError!graph.Graph {
        const dump = tools.pwDump(arena, s.io) catch |err| switch (err) {
            error.MissingTool => die(s.io, "missing dependency: pw-dump", .{}),
            error.ToolFailed => return error.Unreadable,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const listing: seq.Listing = if (s.seq) |open| try open.list(arena) else .none;
        const midi = try alsa.parse(arena, listing, s.show_all);
        var g = pipewire.parse(arena, dump, midi) catch |err| switch (err) {
            error.InvalidDump => return error.Unreadable,
            else => |e| return e,
        };
        try g.applyAliases(arena, s.aliases);
        return g;
    }
};

/// Reads the graph for the TUI, every second.
const Scanner = struct {
    source: Source,

    pub fn scan(s: Scanner, arena: Allocator) tui.ScanError!graph.Graph {
        return s.source.read(arena);
    }
};

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

fn dieMissing(io: Io, missing: []const tools.Tool) noreturn {
    var buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    stderr.interface.writeAll("aroute: ") catch {};
    tools.explainMissing(&stderr.interface, missing) catch {};
    stderr.interface.flush() catch {};
    std.process.exit(1);
}

/// Puts the terminal back first if the TUI is up.
fn die(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    term.restore();
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

test "ALSA Links go through the sequencer, if there is one" {
    const device = seq.Seq.open("aroute test device") catch return error.SkipZigTest;
    defer device.close();
    const caps: seq.Caps = .{ .read = true, .write = true, .subs_read = true, .subs_write = true };
    const a = try device.createPort("test port A", caps);
    const b = try device.createPort("test port B", caps);
    const s = try seq.Seq.open("aroute");
    defer s.close();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(null, try alsaConnect(s, arena, .{ a, b }));
    try std.testing.expect(alsaDisconnect(s, .{ a, b }));
    try std.testing.expect(!alsaDisconnect(s, .{ a, b }));
    const gone: graph.Addr = .{ .client = device.client, .port = 200 };
    try std.testing.expectEqualStrings("Connection failed (Invalid argument)", (try alsaConnect(s, arena, .{ a, gone })).?);

    // Without a sequencer, as `aconnect` said then.
    try std.testing.expectEqualStrings("can't open sequencer", (try alsaConnect(null, arena, .{ a, b })).?);
    try std.testing.expect(!alsaDisconnect(null, .{ a, b }));
}
