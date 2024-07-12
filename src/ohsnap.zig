//! OhSnap! A Prettified Snapshot Testing Library.
//!
//! Based on a core of TigerBeetle's snaptest.zig[^1].
//!
//! Integrates @timfayz's pretty-printing library, pretty[^2], in order
//! to have general-purpose printing of data structures, and as a regex
//! library, Fluent[^3], by @andrewCodeDev.
//!
//!
//! [^1]: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/testing/snaptest.zig.
//! [^2]: https://github.com/timfayz/pretty
//! [^3]: https://github.com/andrewCodeDev/Fluent

const std = @import("std");
const builtin = @import("builtin");
const Fluent = @import("Fluent");
const pretty = @import("pretty");
const DiffMatchPatch = @import("diffz");
const testing = std.testing;

const assert = std.debug.assert;
const SourceLocation = std.builtin.SourceLocation;

// Intended for use in test mode only.
comptime {
    assert(builtin.is_test);
}

//| Cut code also from TigerBeetle: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/stdx.zig

const Cut = struct {
    prefix: []const u8,
    suffix: []const u8,
};

/// Splits the `haystack` around the first occurrence of `needle`, returning parts before and after.
///
/// This is a Zig version of Go's `string.Cut` / Rust's `str::split_once`. Cut turns out to be a
/// surprisingly versatile primitive for ad-hoc string processing. Often `std.mem.indexOf` and
/// `std.mem.split` can be replaced with a shorter and clearer code using  `cut`.
pub fn cut(haystack: []const u8, needle: []const u8) ?Cut {
    const index = std.mem.indexOf(u8, haystack, needle) orelse return null;

    return Cut{
        .prefix = haystack[0..index],
        .suffix = haystack[index + needle.len ..],
    };
}

const ignore_regex_string = "<\\^.+\\$>";

test "init regex" {
    const haystack = "012345678<^[a-d0-9]+$> blah blah";
    var iter = Fluent.match(ignore_regex_string, haystack);
    while (iter.next()) |found| {
        const start, const len = .{ iter.index - found.items.len, found.items.len };
        std.debug.print("found at: {d} length {d} {}\n", .{ start, len, found });
    }
}

pub const Snap = struct {
    location: SourceLocation,
    text: []const u8,
    update_this: bool = false,
    pretty: bool = true,

    // const ignore_regex = Fluent.match(ignore_regex_string);
    /// Creates a new Snap.
    ///
    /// For the update logic to work, *must* be formatted as:
    ///
    /// ```
    /// snap(@src(),
    ///     \\Text of the snapshot.
    /// )
    /// ```
    pub fn snap(location: SourceLocation, text: []const u8) Snap {
        return Snap{ .location = location, .text = text };
    }

    pub fn snapfmt(location: SourceLocation, text: []const u8) Snap {
        return Snap{ .location = location, .text = text, .pretty = false };
    }

    /// Builder-lite method to update just this particular snapshot.
    pub fn update(snapshot: *const Snap) Snap {
        return Snap{
            .location = snapshot.location,
            .text = snapshot.text,
            .update_this = true,
        };
    }

    /// Compare the snapshot with a formatted string.
    pub fn diff_fmt(snapshot: *const Snap, args: anytype) !void {
        const got = get: {
            if (snapshot.pretty) // TODO look into options here
                break :get try pretty.dump(testing.allocator, args, .{})
            else
                break :get try std.fmt.allocPrint(testing.allocator, "{any}", args);
        };
        defer std.testing.allocator.free(got);

        try snapshot.diff(got);
    }

    /// Compare the snapshot with a given string.
    pub fn diff(snapshot: *const Snap, got: []const u8) !void {
        if (equalExcludingIgnored(got, snapshot.text)) return;
        // TODO add diff library, use here
        std.debug.print(
            \\Snapshot differs.
            \\Want:
            \\----
            \\{s}
            \\----
            \\Got:
            \\----
            \\{s}
            \\----
            \\
        ,
            .{
                snapshot.text,
                got,
            },
        );

        // TODO check for magic <!update> string here
        if (false) {
            std.debug.print(
                \\To accept this update, replace the start of the first line
                \\with:
                \\<!update>
                \\
            ,
                .{},
            );
            return error.SnapDiff;
        }

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        const file_text =
            try std.fs.cwd().readFileAlloc(allocator, snapshot.location.file, 1024 * 1024);
        var file_text_updated = try std.ArrayList(u8).initCapacity(allocator, file_text.len);

        const line_zero_based = snapshot.location.line - 1;
        const range = snapRange(file_text, line_zero_based);

        const snapshot_prefix = file_text[0..range.start];
        const snapshot_text = file_text[range.start..range.end];
        const snapshot_suffix = file_text[range.end..];

        const indent = getIndent(snapshot_text);

        try file_text_updated.appendSlice(snapshot_prefix);
        {
            var lines = std.mem.split(u8, got, "\n");
            while (lines.next()) |line| {
                try file_text_updated.writer().print("{s}\\\\{s}\n", .{ indent, line });
            }
        }
        try file_text_updated.appendSlice(snapshot_suffix);

        try std.fs.cwd().writeFile(.{
            .sub_path = snapshot.location.file,
            .data = file_text_updated.items,
        });

        std.debug.print("Updated {s}\n", .{snapshot.location.file});
        return error.SnapUpdated;
    }
};

fn equalExcludingIgnored(got: []const u8, snapshot: []const u8) bool {
    var got_rest = got;
    var snapshot_rest = snapshot;

    // Don't allow ignoring suffixes and prefixes, as that makes it easy to miss trailing or leading
    // data.
    assert(!std.mem.startsWith(u8, snapshot, "<snap:ignore>"));
    assert(!std.mem.endsWith(u8, snapshot, "<snap:ignore>"));

    for (0..10) |_| {
        // Cut the part before the first ignore, it should be equal between two strings...
        const snapshot_cut = cut(snapshot_rest, "<snap:ignore>") orelse break;
        const got_cut = cut(got_rest, snapshot_cut.prefix) orelse return false;
        if (got_cut.prefix.len != 0) return false;
        got_rest = got_cut.suffix;
        snapshot_rest = snapshot_cut.suffix;

        // ...then find the next part that should match, and cut up to that.
        const next_match = if (cut(snapshot_rest, "<snap:ignore>")) |snapshot_cut_next|
            snapshot_cut_next.prefix
        else
            snapshot_rest;
        assert(next_match.len > 0);
        snapshot_rest = cut(snapshot_rest, next_match).?.suffix;

        const got_cut_next = cut(got_rest, next_match) orelse return false;
        const ignored = got_cut_next.prefix;
        // If <snap:ignore> matched an empty string, or several lines, report it as an error.
        if (ignored.len == 0) return false;
        if (std.mem.indexOf(u8, ignored, "\n") != null) return false;
        got_rest = got_cut_next.suffix;
    } else @panic("more than 10 ignores");

    return std.mem.eql(u8, got_rest, snapshot_rest);
}

test equalExcludingIgnored {
    const TestCase = struct { got: []const u8, snapshot: []const u8 };

    const cases_ok: []const TestCase = &.{
        .{ .got = "ABA", .snapshot = "ABA" },
        .{ .got = "ABBA", .snapshot = "A<snap:ignore>A" },
        .{ .got = "ABBACABA", .snapshot = "AB<snap:ignore>CA<snap:ignore>A" },
    };
    for (cases_ok) |case| {
        try std.testing.expect(equalExcludingIgnored(case.got, case.snapshot));
    }

    const cases_err: []const TestCase = &.{
        .{ .got = "ABA", .snapshot = "ACA" },
        .{ .got = "ABBA", .snapshot = "A<snap:ignore>C" },
        .{ .got = "ABBACABA", .snapshot = "AB<snap:ignore>DA<snap:ignore>BA" },
        .{ .got = "ABBACABA", .snapshot = "AB<snap:ignore>BA<snap:ignore>DA" },
        .{ .got = "ABA", .snapshot = "AB<snap:ignore>A" },
        .{ .got = "A\nB\nA", .snapshot = "A<snap:ignore>A" },
    };
    for (cases_err) |case| {
        try std.testing.expect(!equalExcludingIgnored(case.got, case.snapshot));
    }
}

const Range = struct { start: usize, end: usize };

/// Extracts the range of the snapshot. Assumes that the snapshot is formatted as
///
/// ```
/// snap(@src(),
///     \\first line
///     \\second line
/// )
/// ```
///
/// We could make this more robust by using `std.zig.Ast`, but sticking to manual string processing
/// is simpler, and enforced consistent style of snapshots is a good thing.
///
/// While we expect to find a snapshot after a given line, this is not guaranteed (the file could
/// have been modified between compilation and running the test), but should be rare enough to
/// just fail with an assertion.
fn snapRange(text: []const u8, src_line: u32) Range {
    var offset: usize = 0;
    var line_number: u32 = 0;

    var lines = std.mem.split(u8, text, "\n");
    const snap_start = while (lines.next()) |line| : (line_number += 1) {
        if (line_number == src_line) {
            if (std.mem.indexOf(u8, line, "@src()") == null) {
                std.debug.print(
                    "Expected snapshot @src() on line {d}.\n",
                    .{line_number + 1},
                );
            }
            try testing.expect(false);
        }
        if (line_number == src_line + 1) {
            if (!isMultilineString(line)) {
                std.debug.print(
                    "Expected multiline string `\\\\` on line {d}.\n",
                    .{line_number + 1},
                );
                try testing.expect(false);
            }
            break offset;
        }
        offset += line.len + 1; // 1 for \n
    } else unreachable;

    lines = std.mem.split(u8, text[snap_start..], "\n");
    const snap_end = while (lines.next()) |line| {
        if (!isMultilineString(line)) {
            break offset;
        }
        offset += line.len + 1; // 1 for \n
    } else unreachable;

    return Range{ .start = snap_start, .end = snap_end };
}

fn isMultilineString(line: []const u8) bool {
    for (line, 0..) |c, i| {
        switch (c) {
            ' ' => {},
            '\\' => return (i + 1 < line.len and line[i + 1] == '\\'),
            else => return false,
        }
    }
    return false;
}

fn getIndent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ') return line[0..i];
    }
    return line;
}
