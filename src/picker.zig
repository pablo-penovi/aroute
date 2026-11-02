//! Picking items by letter (docs/design.md → Picking items): letters go only
//! to the rows on screen, always `a`… from the top (`a`–`z`, then `A`–`Z`),
//! and `PgUp`/`PgDn` page through the list, giving the letters to the new
//! rows. A page is as many rows as fit, at most 52.

const std = @import("std");

pub const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// A list of `total` items, `size` to a page.
pub const Pages = struct {
    total: usize,
    /// Rows per page; 0 when no row fits.
    size: usize,

    /// `total` items, with `rows` rows on screen for them.
    pub fn init(total: usize, rows: usize) Pages {
        return .{ .total = total, .size = @min(rows, letters.len) };
    }

    /// How many pages there are; always at least one, even if empty.
    pub fn count(p: Pages) usize {
        if (p.size == 0 or p.total == 0) return 1;
        return std.math.divCeil(usize, p.total, p.size) catch unreachable;
    }

    /// `page`, pulled back to the last one if past it.
    pub fn clamp(p: Pages, page: usize) usize {
        return @min(page, p.count() - 1);
    }

    pub fn next(p: Pages, page: usize) usize {
        return p.clamp(page + 1);
    }

    pub fn prev(p: Pages, page: usize) usize {
        return p.clamp(page) -| 1;
    }

    /// The items on one page.
    pub const Slice = struct { start: usize, len: usize };

    /// The first item on `page`, and how many are on it.
    pub fn slice(p: Pages, page: usize) Slice {
        const start = p.clamp(page) * p.size;
        return .{ .start = start, .len = @min(p.size, p.total - start) };
    }

    /// The item that `key` picks on `page`, if any.
    pub fn pick(p: Pages, page: usize, key: u21) ?usize {
        const row = std.mem.findScalar(u8, letters, std.math.cast(u8, key) orelse return null) orelse return null;
        const s = p.slice(page);
        if (row >= s.len) return null;
        return s.start + row;
    }

    /// The page `item` is on.
    pub fn pageOf(p: Pages, item: usize) usize {
        if (p.size == 0) return 0;
        return p.clamp(item / p.size);
    }
};

/// The letter of the `row`th row on a page.
pub fn letter(row: usize) u8 {
    return letters[row];
}

const testing = std.testing;

test "a list shorter than a page: one page, letters from `a`" {
    const p: Pages = .init(3, 10);
    try testing.expectEqual(1, p.count());
    try testing.expectEqual(0, p.next(0));
    try testing.expectEqual(0, p.prev(0));
    try testing.expectEqual(3, p.slice(0).len);
    try testing.expectEqual(0, p.pick(0, 'a'));
    try testing.expectEqual(2, p.pick(0, 'c'));
    try testing.expectEqual(null, p.pick(0, 'd'));
    try testing.expectEqual(null, p.pick(0, 'A'));
    try testing.expectEqual(null, p.pick(0, '1'));
    try testing.expectEqual(null, p.pick(0, 'é'));
}

test "a list exactly a page long" {
    const p: Pages = .init(10, 10);
    try testing.expectEqual(1, p.count());
    try testing.expectEqual(0, p.next(0));
    try testing.expectEqual(9, p.pick(0, 'j'));
    try testing.expectEqual(null, p.pick(0, 'k'));
}

test "a list longer than a page: letters start at `a` on every page" {
    const p: Pages = .init(23, 10);
    try testing.expectEqual(3, p.count());
    try testing.expectEqual(1, p.next(0));
    try testing.expectEqual(2, p.next(1));
    try testing.expectEqual(2, p.next(2));
    try testing.expectEqual(1, p.prev(2));
    try testing.expectEqual(0, p.prev(0));
    try testing.expectEqual(10, p.pick(1, 'a'));
    try testing.expectEqual(19, p.pick(1, 'j'));
    // The last page is short.
    try testing.expectEqual(3, p.slice(2).len);
    try testing.expectEqual(22, p.pick(2, 'c'));
    try testing.expectEqual(null, p.pick(2, 'd'));
    try testing.expectEqual(2, p.pageOf(22));
    try testing.expectEqual(1, p.pageOf(10));
    try testing.expectEqual(0, p.pageOf(9));
}

test "a page is at most 52 rows, `a`–`z` then `A`–`Z`" {
    const p: Pages = .init(120, 80);
    try testing.expectEqual(52, p.size);
    try testing.expectEqual(3, p.count());
    try testing.expectEqual(25, p.pick(0, 'z'));
    try testing.expectEqual(26, p.pick(0, 'A'));
    try testing.expectEqual(51, p.pick(0, 'Z'));
    try testing.expectEqual(52, p.pick(1, 'a'));
    try testing.expectEqual(103, p.pick(1, 'Z'));
    try testing.expectEqual(16, p.slice(2).len);
    try testing.expectEqual(119, p.pick(2, 'p'));
    try testing.expectEqual(null, p.pick(2, 'q'));
    try testing.expectEqual('a', letter(0));
    try testing.expectEqual('A', letter(26));
    try testing.expectEqual('Z', letter(51));
}

test "a page past the end, after the list or the screen shrank, is the last one" {
    const p: Pages = .init(23, 10);
    try testing.expectEqual(2, p.clamp(7));
    try testing.expectEqual(20, p.slice(7).start);
    try testing.expectEqual(1, p.prev(7));
    try testing.expectEqual(20, p.pick(7, 'a'));
}

test "an empty list, or no room for any row" {
    const empty: Pages = .init(0, 10);
    try testing.expectEqual(1, empty.count());
    try testing.expectEqual(0, empty.slice(0).len);
    try testing.expectEqual(null, empty.pick(0, 'a'));

    const none: Pages = .init(5, 0);
    try testing.expectEqual(1, none.count());
    try testing.expectEqual(0, none.slice(0).len);
    try testing.expectEqual(null, none.pick(0, 'a'));
    try testing.expectEqual(0, none.pageOf(4));
}
