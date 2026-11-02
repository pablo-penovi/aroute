//! A line typed on the status line, as the script's `prompt_line`: a Profile
//! name, or the answer to a `(y/n)` question. Only the characters a Profile
//! name may hold go in (letters, digits, space, `.`, `_`, `-`), and `Enter`
//! needs something typed.

const std = @import("std");
const term = @import("term.zig");

pub const Field = struct {
    buf: [max_len]u8 = @splat(0),
    len: usize = 0,

    /// The longest Profile name whose file, `<name>.conf`, still has a
    /// name of at most 255 bytes; what is typed past it is dropped.
    pub const max_len = 255 - ".conf".len;

    /// A field holding `s`, cut to `max_len`.
    pub fn init(s: []const u8) Field {
        var f: Field = .{ .len = @min(s.len, max_len) };
        @memcpy(f.buf[0..f.len], s[0..f.len]);
        return f;
    }

    pub fn text(f: *const Field) []const u8 {
        return f.buf[0..f.len];
    }

    /// Whether the answer to a `(y/n)` question is yes: it starts with `y`
    /// or `Y`, as the script's `[yY]*`.
    pub fn yes(f: *const Field) bool {
        return f.len > 0 and (f.buf[0] == 'y' or f.buf[0] == 'Y');
    }

    /// What a key did.
    pub const Outcome = enum {
        /// Typed, erased, or ignored: keep asking.
        typing,
        /// `Enter` with something typed.
        done,
        /// `Esc`.
        cancel,
    };

    pub fn key(f: *Field, k: term.Key) Outcome {
        switch (k) {
            .char => |c| if (f.len < max_len and allowed(c)) {
                f.buf[f.len] = @intCast(c);
                f.len += 1;
            },
            .backspace => if (f.len > 0) {
                f.len -= 1;
                f.buf[f.len] = 0;
            },
            .enter => if (f.len > 0) return .done,
            .esc => return .cancel,
            .tab, .page_up, .page_down, .other => {},
        }
        return .typing;
    }
};

fn allowed(c: u21) bool {
    const b = std.math.cast(u8, c) orelse return false;
    return std.ascii.isAlphanumeric(b) or std.mem.findScalar(u8, " ._-", b) != null;
}

const testing = std.testing;

test "Field: only the characters of a Profile name go in" {
    var f: Field = .{};
    for ("Mic-Line 2_b.x") |c| try testing.expectEqual(.typing, f.key(.{ .char = c }));
    for ("/:|'ñ") |c| _ = f.key(.{ .char = c });
    _ = f.key(.{ .char = 'é' });
    _ = f.key(.{ .char = 'ー' });
    for ([_]term.Key{ .tab, .page_up, .page_down, .other }) |k| try testing.expectEqual(.typing, f.key(k));
    try testing.expectEqualStrings("Mic-Line 2_b.x", f.text());
}

test "Field: Backspace erases; Enter needs something typed; Esc cancels" {
    var f: Field = .init("ab");
    try testing.expectEqual(.typing, f.key(.backspace));
    try testing.expectEqualDeep(Field.init("a"), f);
    try testing.expectEqual(.done, f.key(.enter));
    _ = f.key(.backspace);
    try testing.expectEqual(.typing, f.key(.backspace));
    try testing.expectEqualDeep(Field{}, f);
    try testing.expectEqual(.typing, f.key(.enter));
    try testing.expectEqual(.cancel, f.key(.esc));
    f = .init("x");
    try testing.expectEqual(.cancel, f.key(.esc));
}

test "Field: what doesn't fit is dropped" {
    const long: [Field.max_len + 5]u8 = @splat('x');
    var f: Field = .init(&long);
    try testing.expectEqual(Field.max_len, f.text().len);
    _ = f.key(.{ .char = 'y' });
    try testing.expectEqual(Field.max_len, f.text().len);
    try testing.expectEqual('x', f.text()[Field.max_len - 1]);
}

test "Field.yes: starts with y or Y" {
    for ([_][]const u8{ "y", "Y", "yes", "Yep" }) |s| try testing.expect(Field.init(s).yes());
    for ([_][]const u8{ "", "n", "no", " y", "ny" }) |s| try testing.expect(!Field.init(s).yes());
}
