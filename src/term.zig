//! The terminal, hand-written (no dependencies): raw input on the alternate
//! screen, its size, reading keys, and always putting it back as it was, as
//! the script's `tui`, `readkey` and `cleanup` do. Linux only, like PipeWire.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Size = @import("screen.zig").Size;

const stdin = posix.STDIN_FILENO;
const stdout = posix.STDOUT_FILENO;

/// The terminal settings to go back to; set while the TUI is up.
var saved: ?posix.termios = null;

/// Run, if set, when Ctrl-C or SIGTERM ends aroute, once the terminal is
/// back: what else to put back or stop. Must be safe in a signal handler.
pub var on_interrupt: ?*const fn () void = null;

/// Set by SIGWINCH, cleared by `Input.next` when it reports the resize.
var resized: std.atomic.Value(bool) = .init(false);

const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[2J";
/// Reset colours, show the cursor, leave the alternate screen.
const leave_screen = "\x1b[0m\x1b[?25h\x1b[?1049l";

/// Switches to the alternate screen with the cursor hidden and input
/// unbuffered and not echoed, as the script's `stty -echo -icanon min 1
/// time 0` (so Ctrl-C still interrupts), until `restore`. Ctrl-C and SIGTERM
/// restore the terminal, run `on_interrupt`, and exit with 130, as in the script.
pub fn enter() posix.TermiosGetError!void {
    const original = try posix.tcgetattr(stdin);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;

    handle(.INT, onInterrupt);
    handle(.TERM, onInterrupt);
    handle(.WINCH, onResize);
    saved = original;
    posix.tcsetattr(stdin, .NOW, raw) catch |err| {
        saved = null;
        return switch (err) {
            error.ProcessOrphaned => error.Unexpected,
            else => |e| e,
        };
    };
    writeAll(enter_screen);
}

/// Puts the terminal back as `enter` found it; does nothing if it wasn't
/// entered or is already restored. Safe to call from a signal handler.
pub fn restore() void {
    const original = saved orelse return;
    saved = null;
    writeAll(leave_screen);
    posix.tcsetattr(stdin, .NOW, original) catch {};
}

fn handle(sig: posix.SIG, handler: *const fn (posix.SIG) callconv(.c) void) void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = posix.sigemptyset(),
        // `poll` is never restarted, so a resize still wakes it.
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(sig, &act, null);
}

fn onInterrupt(_: posix.SIG) callconv(.c) void {
    restore();
    if (on_interrupt) |f| f();
    std.process.exit(130);
}

fn onResize(_: posix.SIG) callconv(.c) void {
    resized.store(true, .release);
}

/// Unbuffered, for signal handlers; gives up on any error.
fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(stdout, rest.ptr, rest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR => {},
            else => return,
        }
    }
}

/// The terminal's size, or 24×80 (as the script) if it can't be read.
pub fn size() Size {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(stdout, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS or ws.row == 0 or ws.col == 0) return .fallback;
    return .{ .rows = ws.row, .cols = ws.col };
}

pub const Key = union(enum) {
    /// A printable character.
    char: u21,
    esc,
    enter,
    tab,
    backspace,
    page_up,
    page_down,
    /// Any other key: arrows, function keys, Alt+key, other control characters.
    other,
};

pub const Parsed = struct { key: Key, len: usize };

/// The key at the start of `bytes` (not empty) and how many bytes it takes.
/// ESC is the Esc key only when nothing follows it; otherwise it starts an
/// escape sequence, as in the script's `readkey`.
pub fn parseKey(bytes: []const u8) Parsed {
    const c = bytes[0];
    switch (c) {
        0x1b => return parseEscape(bytes),
        '\r', '\n' => return .{ .key = .enter, .len = 1 },
        '\t' => return .{ .key = .tab, .len = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .len = 1 },
        0...0x07, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f => return .{ .key = .other, .len = 1 },
        else => {},
    }
    const n = std.unicode.utf8ByteSequenceLength(c) catch return .{ .key = .other, .len = 1 };
    if (n > bytes.len) return .{ .key = .other, .len = 1 };
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .key = .other, .len = 1 };
    return .{ .key = .{ .char = cp }, .len = n };
}

fn parseEscape(bytes: []const u8) Parsed {
    if (bytes.len == 1) return .{ .key = .esc, .len = 1 };
    switch (bytes[1]) {
        // CSI: parameter bytes, intermediate bytes, then a final byte.
        '[' => {
            var i: usize = 2;
            while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] < 0x40) i += 1;
            // Cut short: drop what there is.
            if (i == bytes.len) return .{ .key = .other, .len = i };
            const seq = bytes[2 .. i + 1];
            const key: Key = if (std.mem.eql(u8, seq, "5~")) .page_up else if (std.mem.eql(u8, seq, "6~")) .page_down else .other;
            return .{ .key = key, .len = i + 1 };
        },
        // SS3: one more byte (F1–F4, arrows in application mode).
        'O' => return .{ .key = .other, .len = @min(3, bytes.len) },
        // Alt+key.
        else => return .{ .key = .other, .len = 2 },
    }
}

pub const Event = union(enum) {
    key: Key,
    resize,
    /// One of the other files waited on is readable: the graph may have changed.
    changed,
    /// Nothing happened before the timeout.
    timeout,
};

/// How long to wait for the rest of an escape sequence after ESC, as the script.
const escape_ms = 30;

/// Keys from the terminal.
pub const Input = struct {
    /// Where keys come from.
    fd: posix.fd_t = stdin,
    buf: [64]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub const Error = error{EndOfInput};

    /// The most other files `next` waits on.
    pub const max_others = 3;

    /// The next key, a resize, `.changed` once one of `others` is readable
    /// (keys come first), or `.timeout` after `timeout_ms` (-1: no limit).
    pub fn next(in: *Input, timeout_ms: i32, others: []const posix.fd_t) Error!Event {
        while (true) {
            if (resized.swap(false, .acquire)) return .resize;
            if (in.start < in.end) {
                const k = parseKey(in.buf[in.start..in.end]);
                in.start += k.len;
                return .{ .key = k.key };
            }
            switch (wait(in.fd, others, timeout_ms)) {
                .timeout => return .timeout,
                // A resize, checked at the top.
                .interrupted => continue,
                .other => return .changed,
                .key => {},
            }
            in.start = 0;
            in.end = try read(in.fd, &in.buf);
            if (in.end == 1 and in.buf[0] == 0x1b and wait(in.fd, &.{}, escape_ms) == .key) {
                in.end += try read(in.fd, in.buf[1..]);
            }
        }
    }
};

fn wait(fd: posix.fd_t, others: []const posix.fd_t, timeout_ms: i32) enum { key, other, timeout, interrupted } {
    std.debug.assert(others.len <= Input.max_others);
    var fds: [1 + Input.max_others]posix.pollfd = undefined;
    fds[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
    for (others, fds[1..][0..others.len]) |o, *p| p.* = .{ .fd = o, .events = posix.POLL.IN, .revents = 0 };
    const polled = fds[0 .. 1 + others.len];
    const rc = linux.poll(polled.ptr, polled.len, timeout_ms);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) .timeout else if (fds[0].revents != 0) .key else .other,
        .INTR => .interrupted,
        // Let `read` say what is wrong.
        else => .key,
    };
}

/// The terminal is gone when it reads nothing or fails.
fn read(fd: posix.fd_t, buf: []u8) Input.Error!usize {
    const n = posix.read(fd, buf) catch return error.EndOfInput;
    if (n == 0) return error.EndOfInput;
    return n;
}

const testing = std.testing;

fn expectKey(expected: Key, len: usize, bytes: []const u8) !void {
    const p = parseKey(bytes);
    try testing.expectEqual(expected, p.key);
    try testing.expectEqual(len, p.len);
}

test "parseKey: characters and control keys" {
    try expectKey(.{ .char = 'a' }, 1, "abc");
    try expectKey(.{ .char = '1' }, 1, "1");
    try expectKey(.{ .char = ' ' }, 1, " ");
    try expectKey(.{ .char = 'é' }, 2, "é!");
    try expectKey(.{ .char = '日' }, 3, "日本");
    try expectKey(.enter, 1, "\r");
    try expectKey(.enter, 1, "\n");
    try expectKey(.tab, 1, "\t");
    try expectKey(.backspace, 1, "\x7f");
    try expectKey(.backspace, 1, "\x08");
    try expectKey(.other, 1, "\x01");
    // Invalid or cut-short UTF-8.
    try expectKey(.other, 1, "\xff");
    try expectKey(.other, 1, "\xe6\x97");
}

test "parseKey: Esc alone, PgUp/PgDn, other escape sequences" {
    try expectKey(.esc, 1, "\x1b");
    try expectKey(.page_up, 4, "\x1b[5~");
    try expectKey(.page_down, 4, "\x1b[6~x");
    // Shift+PgDn, an arrow, F5, F1 in application mode, Alt+x.
    try expectKey(.other, 6, "\x1b[6;2~");
    try expectKey(.other, 3, "\x1b[A");
    try expectKey(.other, 5, "\x1b[15~");
    try expectKey(.other, 3, "\x1bOP");
    try expectKey(.other, 2, "\x1bx");
    // Cut short.
    try expectKey(.other, 3, "\x1b[5");
    try expectKey(.other, 2, "\x1bO");
}

test "parseKey: several keys in a row, as when pasted" {
    const bytes = "\x1b[6~a\x1b[5~\r";
    var i: usize = 0;
    var keys: [4]Key = undefined;
    for (&keys) |*k| {
        const p = parseKey(bytes[i..]);
        k.* = p.key;
        i += p.len;
    }
    try testing.expectEqual(bytes.len, i);
    try testing.expectEqualSlices(Key, &.{ .page_down, .{ .char = 'a' }, .page_up, .enter }, &keys);
}

fn pipe() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    return fds;
}

fn closeAll(fds: [2]posix.fd_t) void {
    for (fds) |fd| _ = linux.close(fd);
}

fn send(fd: posix.fd_t, bytes: []const u8) !void {
    if (posix.errno(linux.write(fd, bytes.ptr, bytes.len)) != .SUCCESS) return error.WriteFailed;
}

test "Input: another file readable is a change; keys still arrive, first" {
    const keys = try pipe();
    defer closeAll(keys);
    const graph = try pipe();
    defer closeAll(graph);
    var in: Input = .{ .fd = keys[0] };
    const others = [_]posix.fd_t{graph[0]};

    try testing.expectEqual(Event.timeout, try in.next(0, &others));
    try send(graph[1], "x");
    try testing.expectEqual(Event.changed, try in.next(-1, &others));
    // Until it is read, it stays readable.
    try testing.expectEqual(Event.changed, try in.next(0, &others));

    try send(keys[1], "a\x1b[6~");
    try testing.expectEqual(Event{ .key = .{ .char = 'a' } }, try in.next(-1, &others));
    try testing.expectEqual(Event{ .key = .page_down }, try in.next(-1, &others));
    try testing.expectEqual(Event.changed, try in.next(-1, &others));

    // Without it, the same as before: only keys.
    try testing.expectEqual(Event.timeout, try in.next(0, &.{}));
    try send(keys[1], "\x1b");
    try testing.expectEqual(Event{ .key = .esc }, try in.next(-1, &.{}));
    try send(keys[1], "\x1b[5~");
    try testing.expectEqual(Event{ .key = .page_up }, try in.next(-1, &.{}));
}

test "Input: a terminal that is gone ends the input" {
    const keys = try pipe();
    defer _ = linux.close(keys[0]);
    _ = linux.close(keys[1]);
    var in: Input = .{ .fd = keys[0] };
    try testing.expectError(error.EndOfInput, in.next(-1, &.{}));
}
