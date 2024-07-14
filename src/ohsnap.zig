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

const OhSnap = @This();

pretty_options: pretty.Options = pretty.Options{
    .max_depth = 0,
    .struct_max_len = 0,
    .array_max_len = 0,
    .array_show_prim_type_info = true,
    .type_name_max_len = 0,
    .str_max_len = 0,
    .show_tree_lines = true,
},

//| Cut code also from TigerBeetle: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/stdx.zig

const Cut = struct {
    prefix: []const u8,
    suffix: []const u8,
};

/// Creates a new Snap using `pretty` formatting.
///
/// For the update logic to work, *must* be formatted as:
///
/// ```
/// try oh.snap(@src(),
///     \\Text of the snapshot.
/// ).expectEqual(val);
/// ```
/// With the `@src()` on the line before the text, which must be
/// in multi-line format.
pub fn snap(ohsnap: OhSnap, location: SourceLocation, text: []const u8) Snap {
    return Snap{
        .location = location,
        .text = text,
        .ohsnap = ohsnap,
    };
}

/// Creates a new Snap using the type's `.format` method.
///
/// For the update logic to work, *must* be formatted as:
///
/// ```
/// try oh.snapfmt(@src(),
///     \\Text of the snapshot.
/// ).expectEqual(val);
/// ```
/// With the `@src()` on the line before the text, which must be
/// in multi-line format.
pub fn snapfmt(ohsnap: OhSnap, location: SourceLocation, text: []const u8) Snap {
    return Snap{
        .location = location,
        .text = text,
        .ohsnap = ohsnap,
        .pretty = false,
    };
}

// TODO we probably don't need this.
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

// Regex for detecting embedded regexen
const ignore_regex_string = "<\\^.+\\$>";

pub const Snap = struct {
    location: SourceLocation,
    text: []const u8,
    ohsnap: OhSnap,
    pretty: bool = true,

    const allocator = std.testing.allocator;

    /// Compare the snapshot with a formatted string.
    pub fn expectEqual(snapshot: *const Snap, args: anytype) !void {
        const got = get: {
            if (snapshot.pretty) // TODO look into options here
                break :get try pretty.dump(
                    allocator,
                    args,
                    snapshot.ohsnap.pretty_options,
                )
            else
                break :get try std.fmt.allocPrint(allocator, "{any}", args);
        };
        defer std.testing.allocator.free(got);

        try snapshot.diff(got);
    }

    /// Compare the snapshot with a given string.
    pub fn diff(snapshot: *const Snap, got: []const u8) !void {
        // TODO check for magic <!update> string here
        const update_idx = std.mem.indexOf(u8, snapshot.text, "<!update>");
        if (update_idx) |idx| {
            if (idx == 0) {
                return try updateSnap(snapshot, got);
            } else {
                // Probably a user mistake but the diff logic will surface that
            }
        }

        const dmp = DiffMatchPatch{ .diff_timeout = 0 };
        var diffs = try dmp.diff(allocator, snapshot.text, got, false);
        defer DiffMatchPatch.deinitDiffList(allocator, &diffs);
        if (diffDiffers(diffs)) {
            const diff_string = try DiffMatchPatch.diffPrettyFormatXTerm(allocator, diffs);
            defer allocator.free(diff_string);
            std.debug.print(
                \\Snapshot differs:
                \\
                \\{s}
                \\
                \\ To replace contents, add <!update> as the first line of the snap text.
                \\
            ,
                .{diff_string},
            );
        }
    }

    fn updateSnap(snapshot: *const Snap, got: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();

        const file_text =
            try std.fs.cwd().readFileAlloc(arena_allocator, snapshot.location.file, 1024 * 1024);
        var file_text_updated = try std.ArrayList(u8).initCapacity(arena_allocator, file_text.len);

        const line_zero_based = snapshot.location.line - 1;
        const range = try snapRange(file_text, line_zero_based);

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

fn diffDiffers(diffs: std.ArrayListUnmanaged(DiffMatchPatch.Diff)) bool {
    // TODO decide whether we regex here or in main function.
    var all_equal = true;
    for (diffs.items) |d| {
        switch (d.operation) {
            .equal => {},
            .insert, .delete => {
                all_equal = false;
                break;
            },
        }
    }
    return !all_equal;
}

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
fn snapRange(text: []const u8, src_line: u32) !Range {
    var offset: usize = 0;
    var line_number: u32 = 0;

    var lines = std.mem.split(u8, text, "\n");
    const snap_start = while (lines.next()) |line| : (line_number += 1) {
        if (line_number == src_line) {
            if (std.mem.indexOf(u8, line, "@src()") == null) {
                std.debug.print(
                    "Expected snapshot @src() on line {d}.  Try running tests again.\n",
                    .{line_number + 1},
                );
                try testing.expect(false);
            }
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

test "snap test" {
    const oh = OhSnap{};
    try oh.snap(
        @src(),
        \\struct{comptime foo: *const [10:0]u8 = "bazbuxquux", comptime baz: comptime_int = 27}
        \\  .foo: *const [10:0]u8
        \\    "bazbuxquux"
        \\  .baz: comptime_int = 27
        ,
    ).expectEqual(.{ .foo = "bazbuxquux", .baz = 27 });
}
