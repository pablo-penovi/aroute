//! Text as the terminal shows it: how many columns it takes, and cutting it to
//! fit with `…`. Terminal escape sequences (`\x1b[…m`) take no columns.

const std = @import("std");
const Writer = std.Io.Writer;

/// Columns a code point takes: 0 for control characters and combining marks,
/// 2 for East Asian wide and fullwidth characters and most emoji, 1 for
/// everything else, including East Asian ambiguous ones such as `●`, `…`,
/// `·` and `→`. A short table in the spirit of `wcwidth`, not the full Unicode
/// one; names that need more are rare.
pub fn codepointWidth(cp: u21) u2 {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (cp < 0x300) return 1;
    if (inRanges(cp, &zero_width)) return 0;
    if (inRanges(cp, &double_width)) return 2;
    return 1;
}

const Range = struct { u21, u21 };

/// Combining marks and invisible format characters.
const zero_width = [_]Range{
    .{ 0x0300, 0x036f }, .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05bd },   .{ 0x05bf, 0x05bf },
    .{ 0x05c1, 0x05c2 }, .{ 0x05c4, 0x05c5 }, .{ 0x05c7, 0x05c7 },   .{ 0x0610, 0x061a },
    .{ 0x064b, 0x065f }, .{ 0x0670, 0x0670 }, .{ 0x06d6, 0x06dc },   .{ 0x06df, 0x06e4 },
    .{ 0x06e7, 0x06e8 }, .{ 0x06ea, 0x06ed }, .{ 0x0e31, 0x0e31 },   .{ 0x0e34, 0x0e3a },
    .{ 0x0e47, 0x0e4e }, .{ 0x1ab0, 0x1aff }, .{ 0x1dc0, 0x1dff },   .{ 0x200b, 0x200f },
    .{ 0x202a, 0x202e }, .{ 0x2060, 0x2064 }, .{ 0x20d0, 0x20ff },   .{ 0xfe00, 0xfe0f },
    .{ 0xfe20, 0xfe2f }, .{ 0xfeff, 0xfeff }, .{ 0xe0100, 0xe01ef },
};

/// East Asian wide and fullwidth blocks, and the emoji blocks.
const double_width = [_]Range{
    .{ 0x1100, 0x115f },   .{ 0x231a, 0x231b },   .{ 0x2329, 0x232a },   .{ 0x23e9, 0x23ec },
    .{ 0x23f0, 0x23f0 },   .{ 0x23f3, 0x23f3 },   .{ 0x25fd, 0x25fe },   .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },   .{ 0x267f, 0x267f },   .{ 0x2693, 0x2693 },   .{ 0x26a1, 0x26a1 },
    .{ 0x26aa, 0x26ab },   .{ 0x26bd, 0x26be },   .{ 0x26c4, 0x26c5 },   .{ 0x26ce, 0x26ce },
    .{ 0x26d4, 0x26d4 },   .{ 0x26ea, 0x26ea },   .{ 0x26f2, 0x26f3 },   .{ 0x26f5, 0x26f5 },
    .{ 0x26fa, 0x26fa },   .{ 0x26fd, 0x26fd },   .{ 0x2705, 0x2705 },   .{ 0x270a, 0x270b },
    .{ 0x2728, 0x2728 },   .{ 0x274c, 0x274c },   .{ 0x274e, 0x274e },   .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27b0, 0x27b0 },   .{ 0x27bf, 0x27bf },
    .{ 0x2b1b, 0x2b1c },   .{ 0x2b50, 0x2b50 },   .{ 0x2b55, 0x2b55 },   .{ 0x2e80, 0x303e },
    .{ 0x3041, 0x33ff },   .{ 0x3400, 0x4dbf },   .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },
    .{ 0xa960, 0xa97f },   .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },   .{ 0xfe10, 0xfe19 },
    .{ 0xfe30, 0xfe6f },   .{ 0xff00, 0xff60 },   .{ 0xffe0, 0xffe6 },   .{ 0x16fe0, 0x16fe4 },
    .{ 0x17000, 0x18cff }, .{ 0x1b000, 0x1b2ff }, .{ 0x1f004, 0x1f004 }, .{ 0x1f0cf, 0x1f0cf },
    .{ 0x1f18e, 0x1f18e }, .{ 0x1f191, 0x1f19a }, .{ 0x1f200, 0x1f251 }, .{ 0x1f300, 0x1f64f },
    .{ 0x1f680, 0x1f6ff }, .{ 0x1f7e0, 0x1f7eb }, .{ 0x1f90c, 0x1f9ff }, .{ 0x1fa70, 0x1faff },
    .{ 0x20000, 0x2fffd }, .{ 0x30000, 0x3fffd },
};

fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// One piece of text: a terminal escape sequence, or a character.
const Piece = struct {
    len: usize,
    width: u2,
    escape: bool = false,
};

/// The piece starting at `s[i]`. An invalid UTF-8 byte is a character of its own.
fn piece(s: []const u8, i: usize) Piece {
    if (s[i] == 0x1b) {
        // CSI: `ESC [`, parameter and intermediate bytes, a final byte.
        if (i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and s[j] >= 0x20 and s[j] < 0x40) j += 1;
            return .{ .len = @min(j + 1, s.len) - i, .width = 0, .escape = true };
        }
        return .{ .len = @min(2, s.len - i), .width = 0, .escape = true };
    }
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .len = 1, .width = 1 };
    if (i + n > s.len) return .{ .len = 1, .width = 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .len = 1, .width = 1 };
    return .{ .len = n, .width = codepointWidth(cp) };
}

/// Columns `s` takes on screen.
pub fn width(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const p = piece(s, i);
        w += p.width;
        i += p.len;
    }
    return w;
}

/// Writes text into a fixed number of columns. Text that doesn't fit is cut
/// with `…`, and any text after it is dropped; escape sequences are always
/// written, so styles are still closed.
pub const Line = struct {
    w: *Writer,
    /// Columns still free.
    left: usize,
    /// Text was cut: nothing more is shown.
    full: bool = false,

    pub fn init(w: *Writer, columns: usize) Line {
        return .{ .w = w, .left = columns };
    }

    pub fn text(l: *Line, s: []const u8) Writer.Error!void {
        if (!l.full and width(s) <= l.left) {
            try l.w.writeAll(s);
            l.left -= width(s);
            return;
        }
        // Room for the characters before `…`; none at all once full.
        var room: usize = if (l.full or l.left == 0) 0 else l.left - 1;
        var i: usize = 0;
        while (i < s.len) {
            const p = piece(s, i);
            if (p.escape) {
                try l.w.writeAll(s[i..][0..p.len]);
            } else if (!l.full and p.width <= room) {
                try l.w.writeAll(s[i..][0..p.len]);
                room -= p.width;
                l.left -= p.width;
            } else if (!l.full) {
                l.full = true;
                if (l.left > 0) {
                    try l.w.writeAll("…");
                    l.left -= 1;
                }
            }
            i += p.len;
        }
    }

    /// Fills the remaining columns with spaces.
    pub fn pad(l: *Line) Writer.Error!void {
        try l.w.splatByteAll(' ', l.left);
        l.left = 0;
    }
};

/// `s` in exactly `columns` columns: cut with `…`, or padded with spaces.
pub fn fit(w: *Writer, s: []const u8, columns: usize) Writer.Error!void {
    var l: Line = .init(w, columns);
    try l.text(s);
    try l.pad();
}

const testing = std.testing;

fn fitted(s: []const u8, columns: usize) ![]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var w: Writer = .fixed(&S.buf);
    try fit(&w, s, columns);
    return w.buffered();
}

test "width: ASCII, the TUI's symbols, wide and combining characters, escapes" {
    try testing.expectEqual(0, width(""));
    try testing.expectEqual(10, width("MiniFuse 1"));
    try testing.expectEqual(4, width("●…·→"));
    try testing.expectEqual(1, width("─"));
    try testing.expectEqual(6, width("日本語"));
    try testing.expectEqual(4, width("🎹🎛"));
    // "é" written as e + combining acute accent.
    try testing.expectEqual(4, width("Cafe\u{301}"));
    try testing.expectEqual(4, width("Café"));
    try testing.expectEqual(1, width("\x1b[1m\x1b[36ma\x1b[0m"));
    try testing.expectEqual(0, width("\t\x7f"));
    // Invalid UTF-8: one column per byte.
    try testing.expectEqual(2, width("\xff\xc3"));
}

test "fit: pads, or cuts with … by display width" {
    try testing.expectEqualStrings("abc  ", try fitted("abc", 5));
    try testing.expectEqualStrings("abcde", try fitted("abcde", 5));
    try testing.expectEqualStrings("abcd…", try fitted("abcdef", 5));
    try testing.expectEqualStrings("● Mi…", try fitted("● MiniFuse", 5));
    try testing.expectEqualStrings("", try fitted("abc", 0));
    try testing.expectEqualStrings("…", try fitted("abc", 1));
    // A wide character that doesn't fit before `…` leaves a space.
    try testing.expectEqualStrings("日本…", try fitted("日本語です", 5));
    try testing.expectEqualStrings("日… ", try fitted("日本語です", 4));
    try testing.expectEqualStrings("Café ", try fitted("Café", 5));
}

test "Line: escapes are kept after a cut, later text is dropped" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var l: Line = .init(&w, 6);
    try l.text("\x1b[32m● ");
    try l.text("Speakers");
    try l.text("\x1b[0m");
    try l.text(" → x");
    try l.pad();
    try testing.expectEqualStrings("\x1b[32m● Spe…\x1b[0m", w.buffered());
    try testing.expect(l.full);
    try testing.expectEqual(0, l.left);
}

test "Line: a styled string cut in the middle still closes its style" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var l: Line = .init(&w, 3);
    try l.text("\x1b[1mabcdef\x1b[0m!");
    try testing.expectEqualStrings("\x1b[1mab…\x1b[0m", w.buffered());
}

test "Line: text that exactly fills it leaves nothing for the next" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var l: Line = .init(&w, 3);
    try l.text("abc");
    try l.text("d");
    try l.pad();
    try testing.expectEqualStrings("abc", w.buffered());
}
