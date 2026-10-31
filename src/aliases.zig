//! The `aliases` file: one `text=replacement` per line, applied to every
//! displayed name as a substring replace, in file order. Blank lines, lines
//! starting with `#` and lines without `=` are ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Alias = struct {
    text: []const u8,
    replacement: []const u8,
};

pub const Aliases = struct {
    list: []const Alias = &.{},

    pub const none: Aliases = .{};

    /// Slices of `source` are kept, so it must outlive the result.
    pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!Aliases {
        var list: std.ArrayList(Alias) = .empty;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            // An empty text would match everywhere; the script leaves the name unchanged.
            if (eq == 0) continue;
            try list.append(arena, .{ .text = line[0..eq], .replacement = line[eq + 1 ..] });
        }
        return .{ .list = list.items };
    }

    /// Returns `name` itself when no alias matches.
    pub fn apply(a: Aliases, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
        var out = name;
        for (a.list) |alias| {
            if (std.mem.find(u8, out, alias.text) == null) continue;
            out = try std.mem.replaceOwned(u8, arena, out, alias.text, alias.replacement);
        }
        return out;
    }
};

const testing = std.testing;

test "replaces every occurrence, in file order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try Aliases.parse(arena,
        \\# aroute display names: "text=replacement", applied as a substring replace.
        \\Clipper=M-Vave FM-1
        \\
        \\no equals sign here
        \\Audio Controller=AC
        \\AC Digital=Digital
        \\=ignored
        \\Line2=Loop=back
    );
    try testing.expectEqual(4, a.list.len);
    try testing.expectEqualStrings("M-Vave FM-1 · M-Vave FM-1 MIDI 1", try a.apply(arena, "Clipper · Clipper MIDI 1"));
    try testing.expectEqualStrings("Starship/Matisse HD Digital Stereo", try a.apply(arena, "Starship/Matisse HD Audio Controller Digital Stereo"));
    // Everything after the first `=` is the replacement.
    try testing.expectEqualStrings("Loop=back in", try a.apply(arena, "Line2 in"));
}

test "a name no alias matches is returned as is" {
    const a: Aliases = .{ .list = &.{.{ .text = "x", .replacement = "y" }} };
    const name = "MiniFuse 1";
    try testing.expectEqual(name.ptr, (try a.apply(testing.allocator, name)).ptr);
    try testing.expectEqual(name.ptr, (try Aliases.none.apply(testing.allocator, name)).ptr);
}

test "comment-only and empty files give no aliases" {
    try testing.expectEqual(0, (try Aliases.parse(testing.allocator, "")).list.len);
    try testing.expectEqual(0, (try Aliases.parse(testing.allocator, "# only a comment\n\n")).list.len);
}
