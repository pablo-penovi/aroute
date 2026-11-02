//! `/` search in the pickers (docs/design.md → Search): what a query
//! matches, and what each key does to the search field. The picker owns the
//! list; a `Search` only says how to narrow it and when to go back to page 1.

const std = @import("std");
const term = @import("term.zig");

/// Whether every word of `query` is somewhere in one of `names`, ignoring
/// case: `mini out` matches "MiniFuse 1 Main Output L/R". An empty query
/// matches everything.
pub fn matches(query: []const u8, names: []const []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    next: while (words.next()) |word| {
        for (names) |name| {
            if (std.ascii.findIgnoreCase(name, word) != null) continue :next;
        }
        return false;
    }
    return true;
}

/// The search field of the focused list. Without allocations, so a picker
/// can hold it by value.
pub const Search = struct {
    state: State = .off,
    buf: [max_len]u8 = @splat(0),
    len: usize = 0,

    pub const State = enum {
        /// No field and no filter.
        off,
        /// The field is open: keys go to it, and narrow the list as they come.
        typing,
        /// The field is closed but the list stays narrowed, so letters pick again.
        filtered,
    };

    /// Bytes the field holds; what is typed past it is dropped.
    pub const max_len = 64;

    /// What a key did.
    pub const Outcome = enum {
        /// Not the search's: the picker handles it as without a search.
        pass,
        /// The list may have changed: back to page 1.
        changed,
        /// Taken, and nothing else to do.
        handled,
        /// `Enter` closed the field: with exactly one match, it is picked.
        enter,
    };

    /// What the list is narrowed by; empty when off.
    pub fn query(s: *const Search) []const u8 {
        return s.buf[0..s.len];
    }

    pub fn key(s: *Search, k: term.Key) Outcome {
        return switch (s.state) {
            .off => switch (k) {
                .char => |c| if (c == '/') s.open() else .pass,
                else => .pass,
            },
            .filtered => switch (k) {
                .char => |c| if (c == '/') s.open() else .pass,
                .esc => s.clear(),
                else => .pass,
            },
            .typing => switch (k) {
                .char => |c| s.append(c),
                .backspace => if (s.len == 0) s.clear() else s.erase(),
                .esc => s.clear(),
                .enter => {
                    s.state = if (s.len == 0) .off else .filtered;
                    return .enter;
                },
                .page_up, .page_down, .tab => .pass,
                .other => .handled,
            },
        };
    }

    /// Opens the field, keeping what is in it.
    fn open(s: *Search) Outcome {
        s.state = .typing;
        return .changed;
    }

    fn clear(s: *Search) Outcome {
        s.* = .{};
        return .changed;
    }

    fn append(s: *Search, c: u21) Outcome {
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &bytes) catch return .handled;
        if (s.len + n > max_len) return .handled;
        @memcpy(s.buf[s.len..][0..n], bytes[0..n]);
        s.len += n;
        return .changed;
    }

    /// Drops the last character.
    fn erase(s: *Search) Outcome {
        s.len -= 1;
        // Back over a character's continuation bytes, `10xxxxxx`.
        while (s.len > 0 and s.buf[s.len] & 0xc0 == 0x80) s.len -= 1;
        return .changed;
    }
};

const testing = std.testing;

const minifuse = "MiniFuse 1 Main Output L/R";

test "matches: anywhere in the name, ignoring case" {
    try testing.expect(matches("fuse", &.{minifuse}));
    try testing.expect(matches("MINIFUSE", &.{minifuse}));
    try testing.expect(matches("l/r", &.{minifuse}));
    try testing.expect(!matches("speakers", &.{minifuse}));
    // Not ASCII: as typed.
    try testing.expect(matches("スピ", &.{"日本語のスピーカー"}));
}

test "matches: several words are all required, in any order" {
    try testing.expect(matches("mini out", &.{minifuse}));
    try testing.expect(matches("out  mini ", &.{minifuse}));
    try testing.expect(!matches("mini input", &.{minifuse}));
}

test "matches: each word in either name, as either side of a Connection" {
    try testing.expect(matches("mini renoise", &.{ minifuse, "Renoise" }));
    try testing.expect(matches("renoise", &.{ minifuse, "Renoise" }));
    try testing.expect(!matches("mini synth", &.{ minifuse, "Renoise" }));
}

test "matches: an empty query matches everything" {
    try testing.expect(matches("", &.{minifuse}));
    try testing.expect(matches("   ", &.{minifuse}));
    try testing.expect(matches("", &.{}));
    try testing.expect(!matches("x", &.{}));
}

fn typeIn(s: *Search, keys: []const u8) void {
    for (keys) |c| _ = s.key(.{ .char = c });
}

test "Search: `/` opens the field, and every key narrows" {
    var s: Search = .{};
    try testing.expectEqual(.pass, s.key(.{ .char = 'a' }));
    try testing.expectEqual(.pass, s.key(.esc));
    try testing.expectEqual(.pass, s.key(.enter));
    try testing.expectEqual(.pass, s.key(.backspace));
    try testing.expectEqual(.off, s.state);

    try testing.expectEqual(.changed, s.key(.{ .char = '/' }));
    try testing.expectEqual(.typing, s.state);
    try testing.expectEqualStrings("", s.query());
    // Letters, `/` and `Esc`-less keys all go in.
    for ("mi/ A") |c| try testing.expectEqual(.changed, s.key(.{ .char = c }));
    try testing.expectEqualStrings("mi/ A", s.query());
    try testing.expectEqual(.changed, s.key(.{ .char = 'é' }));
    try testing.expectEqualStrings("mi/ Aé", s.query());
    // Paging and Tab are the picker's; other keys do nothing.
    try testing.expectEqual(.pass, s.key(.page_down));
    try testing.expectEqual(.pass, s.key(.page_up));
    try testing.expectEqual(.pass, s.key(.tab));
    try testing.expectEqual(.handled, s.key(.other));
    try testing.expectEqualStrings("mi/ Aé", s.query());
}

test "Search: Backspace drops a character, and closes an empty field" {
    var s: Search = .{};
    _ = s.key(.{ .char = '/' });
    _ = s.key(.{ .char = 'a' });
    _ = s.key(.{ .char = 'ー' });
    try testing.expectEqual(.changed, s.key(.backspace));
    try testing.expectEqualStrings("a", s.query());
    try testing.expectEqual(.changed, s.key(.backspace));
    try testing.expectEqualStrings("", s.query());
    try testing.expectEqual(.typing, s.state);
    try testing.expectEqual(.changed, s.key(.backspace));
    try testing.expectEqual(.off, s.state);
}

test "Search: Enter keeps the filter, so letters pick; `/` edits it again" {
    var s: Search = .{};
    typeIn(&s, "/mini");
    try testing.expectEqual(.enter, s.key(.enter));
    try testing.expectEqual(.filtered, s.state);
    try testing.expectEqualStrings("mini", s.query());
    // Letters and Backspace are the picker's again.
    try testing.expectEqual(.pass, s.key(.{ .char = 'a' }));
    try testing.expectEqual(.pass, s.key(.backspace));
    try testing.expectEqual(.pass, s.key(.enter));
    try testing.expectEqualStrings("mini", s.query());

    try testing.expectEqual(.changed, s.key(.{ .char = '/' }));
    try testing.expectEqual(.typing, s.state);
    typeIn(&s, " out");
    try testing.expectEqualStrings("mini out", s.query());
}

test "Search: Enter on an empty field closes it" {
    var s: Search = .{};
    _ = s.key(.{ .char = '/' });
    try testing.expectEqual(.enter, s.key(.enter));
    try testing.expectEqual(.off, s.state);
}

test "Search: Esc cancels while typing; with a filter, clears it; then it is the picker's" {
    var s: Search = .{};
    typeIn(&s, "/mini");
    try testing.expectEqual(.changed, s.key(.esc));
    try testing.expectEqual(.off, s.state);
    try testing.expectEqualStrings("", s.query());

    typeIn(&s, "/mini");
    _ = s.key(.enter);
    try testing.expectEqual(.changed, s.key(.esc));
    try testing.expectEqual(.off, s.state);
    try testing.expectEqualStrings("", s.query());
    try testing.expectEqual(.pass, s.key(.esc));

    // Editing a filter and cancelling drops it too.
    typeIn(&s, "/mini");
    _ = s.key(.enter);
    typeIn(&s, "/x");
    _ = s.key(.esc);
    try testing.expectEqual(.off, s.state);
}

test "Search: what doesn't fit is dropped" {
    var s: Search = .{};
    _ = s.key(.{ .char = '/' });
    for (0..Search.max_len - 1) |_| _ = s.key(.{ .char = 'x' });
    try testing.expectEqual(.handled, s.key(.{ .char = 'é' }));
    try testing.expectEqual(.changed, s.key(.{ .char = 'y' }));
    try testing.expectEqual(.handled, s.key(.{ .char = 'z' }));
    try testing.expectEqual(Search.max_len, s.query().len);
    try testing.expectEqual('y', s.query()[Search.max_len - 1]);
    // Not a character: a surrogate half.
    _ = s.key(.backspace);
    try testing.expectEqual(.handled, s.key(.{ .char = 0xd800 }));
}
