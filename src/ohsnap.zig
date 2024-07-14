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
const diffz = @import("diffz");
const testing = std.testing;

const assert = std.debug.assert;
const SourceLocation = std.builtin.SourceLocation;

const DiffList = std.ArrayListUnmanaged(diffz.Diff);
const Diff = diffz.Diff;

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
/// try oh.snap(@src(), // This can be on the next line
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
/// try oh.snapfmt(@src(), // This can be on the next line
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
        defer allocator.free(got);

        try snapshot.diff(got);
    }

    /// Compare the snapshot with a given string.
    pub fn diff(snapshot: *const Snap, got: []const u8) !void {
        // Regex finding regex-ignore regions.
        var regex_finder = Fluent.init(snapshot.text).match(snapshot.text);
        const update_idx = std.mem.indexOf(u8, snapshot.text, "<!update>");
        if (update_idx) |idx| {
            if (idx == 0) {
                if (regex_finder.next()) |_| {
                    std.debug.print("regex handling for updates NYI!\n", .{});
                    return std.testing.expect(false);
                }
                return try updateSnap(snapshot, got);
            } else {
                // Probably a user mistake but the diff logic will surface that
            }
        }

        const dmp = diffz{ .diff_timeout = 0 };
        var diffs = try dmp.diff(allocator, snapshot.text, got, false);
        defer diffz.deinitDiffList(allocator, &diffs);
        if (diffDiffers(diffs)) {
            try diffz.diffCleanupSemantic(allocator, &diffs);
            if (regex_finder.next()) |_| {
                try regexFixup(allocator, &diffs, snapshot, got);
            }
            const diff_string = try diffz.diffPrettyFormatXTerm(allocator, diffs);
            defer allocator.free(diff_string);
            std.debug.print(
                \\Snapshot differs on line {s}{d}{s}:
                \\
                \\{s}
                \\
                \\ To replace contents, add <!update> as the first line of the snap text.
                \\
                \\
            ,
                .{ "\x1b[33m", snapshot.location.line, "\x1b[m", diff_string },
            );
            return try std.testing.expect(false);
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

/// Answer whether the diffs differ (pre-regex, if any)
fn diffDiffers(diffs: DiffList) bool {
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

/// Find regex matches and modify the diff accordingly.
fn regexFixup(
    allocator: std.mem.Allocator,
    diffs: *DiffList,
    snapshot: *const Snap,
    got: []const u8,
) !void {
    var regex_find = Fluent.match(snapshot.text, ignore_regex_string);
    var diffs_idx: usize = 0;
    var snap_idx: usize = 0;
    var got_idx: usize = 0;
    while (regex_find.next()) |found| {
        // Find this location in the got string.
        const snap_start = regex_find.index - found.items.len;
        const snap_end = snap_start + found.items.len;
        const got_start = diffz.diffIndex(diffs.*, snap_start);
        const got_end = diffz.diffIndex(diffs.*, snap_end);
        // Trim the angle brackets off the regex.
        const exclude_regex = found.items[1 .. found.items.len - 1];
        std.debug.print("exclude regex: {s}\n", .{exclude_regex});
        var matcher = Fluent
            .init(got[got_start..got_end])
            .match(exclude_regex);
        const maybe_match = matcher.next();
        // Either way, we zero out the patches, the difference being
        // how we represent the match or not-match in the diff list.
        while (diffs_idx < diffs.items.len) : (diffs_idx += 1) {
            const d = diffs.items[diffs_idx];
            // All patches which are inside one or the other are set to nothing
            const in_snap = snap_start <= snap_idx and snap_start < snap_end;
            const in_got = got_start <= got_idx and got_idx < got_end;
            switch (d.operation) {
                .equal => {
                    // Could easily be in common between the regex and the match.
                    snap_idx += d.text.len;
                    got_idx += d.text.len;
                    if (in_snap and in_got) {
                        allocator.free(d.text);
                        diffs.items[diffs_idx] = Diff{ .operation = .equal, .text = "" };
                    }
                },
                .insert => {
                    // Are we in the match?
                    got_idx += d.text.len;
                    if (in_got) {
                        // Yes, replace with dummy equal
                        allocator.free(d.text);
                        diffs.items[diffs_idx] = Diff{ .operation = .equal, .text = "" };
                    } else {
                        got_idx += d.text.len;
                    }
                },
                .delete => {
                    snap_idx += d.text.len;
                    // Same deal, are we in the match?
                    if (in_snap) {
                        allocator.free(d.text);
                        diffs.items[diffs_idx] = Diff{ .operation = .equal, .text = "" };
                    }
                },
            }
            // Inserts come after deletes, so we check got_idx
            if (got_idx >= got_end) break;
        }
        // Should always mean we have at least two (but we care about
        // having one) diffs rubbed out.
        var formatted = try std.ArrayList(u8).initCapacity(allocator, 10);
        defer formatted.deinit();
        assert(diffs[diffs_idx].operation == .equal and diffs[diffs_idx].text.len == 0);
        if (maybe_match) |m| {
            // Decorate with cyan for a match.
            try formatted.appendSlice("\x1b[36m");
            try formatted.appendSlice(m.items);
            try formatted.appendSlice("\x1b[m");
            diffs[diffs.idx] = Diff{
                .operation = .equal,
                .text = formatted.toOwnedSlice(),
            };
        } else {
            // Decorate magenta for no match, and make it an insert (hence, error)
            try formatted.appendSlice("\x1b[35m");
            try formatted.appendSlice(got[got_start..got_end]);
            try formatted.appendSlice("\x1b[m]");
            diffs[diffs.idx] = Diff{
                .operation = .insert,
                .text = formatted.toOwnedSlice(),
            };
        }
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
    // Change either the snapshot or the struct to make these test fail
    const oh = OhSnap{};
    // Simple anon struct
    try oh.snap(@src(),
        \\struct{comptime foo: *const [10:0]u8 = "bazbuxquux", comptime baz: comptime_int = 27}
        \\  .foo: *const [10:0]u8
        \\    "bazbuxquux"
        \\  .baz: comptime_int = 27
    ).expectEqual(.{ .foo = "bazbuxquux", .baz = 27 });
    // Type
    try oh.snap(
        @src(),
        \\builtin.Type
        \\  .Struct: builtin.Type.Struct
        \\    .layout: builtin.Type.ContainerLayout
        \\      .auto
        \\    .backing_integer: ?type
        \\      null
        \\    .fields: []const builtin.Type.StructField
        \\      [0]: builtin.Type.StructField
        \\        .name: [:0]const u8
        \\          "pretty_options"
        \\        .type: type
        \\          pretty.Options
        \\        .default_value: ?*const anyopaque
        \\        .is_comptime: bool = false
        \\        .alignment: comptime_int = 8
        \\    .decls: []const builtin.Type.Declaration
        \\      [0]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "snap"
        \\      [1]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "snapfmt"
        \\      [2]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "cut"
        \\      [3]: builtin.Type.Declaration
        \\        .name: [:0]const u8
        \\          "Snap"
        \\    .is_tuple: bool = false
        ,
    ).expectEqual(@typeInfo(@This()));
}
