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

/// Set by SIGWINCH, cleared by `Input.next` when it reports the resize.
var resized: std.atomic.Value(bool) = .init(false);

const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[2J";
/// Reset colours, show the cursor, leave the alternate screen.
const leave_screen = "\x1b[0m\x1b[?25h\x1b[?1049l";

/// Switches to the alternate screen with the cursor hidden and input
/// unbuffered and not echoed, as the script's `stty -echo -icanon min 1
/// time 0` (so Ctrl-C still interrupts), until `restore`. Ctrl-C and SIGTERM
/// restore the terminal and exit with 130, as in the script.
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
    /// Nothing happened before the timeout.
    timeout,
};

/// How long to wait for the rest of an escape sequence after ESC, as the script.
const escape_ms = 30;

/// Keys from standard input.
pub const Input = struct {
    buf: [64]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub const Error = error{EndOfInput};

    /// The next key, a resize, or `.timeout` after `timeout_ms`.
    pub fn next(in: *Input, timeout_ms: i32) Error!Event {
        while (true) {
            if (resized.swap(false, .acquire)) return .resize;
            if (in.start < in.end) {
                const k = parseKey(in.buf[in.start..in.end]);
                in.start += k.len;
                return .{ .key = k.key };
            }
            switch (wait(timeout_ms)) {
                .timeout => return .timeout,
                // A resize, checked at the top.
                .interrupted => continue,
                .ready => {},
            }
            in.start = 0;
            in.end = try read(&in.buf);
            if (in.end == 1 and in.buf[0] == 0x1b and wait(escape_ms) == .ready) {
                in.end += try read(in.buf[1..]);
            }
        }
    }
};

fn wait(timeout_ms: i32) enum { ready, timeout, interrupted } {
    var fds = [_]posix.pollfd{.{ .fd = stdin, .events = posix.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&fds, fds.len, timeout_ms);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) .timeout else .ready,
        .INTR => .interrupted,
        // Let `read` say what is wrong.
        else => .ready,
    };
}

/// The terminal is gone when it reads nothing or fails.
fn read(buf: []u8) Input.Error!usize {
    const n = posix.read(stdin, buf) catch return error.EndOfInput;
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
