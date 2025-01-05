//! OhSnap! A Prettified Snapshot Testing Library.
//!
//! Based on a core of TigerBeetle's snaptest.zig[^1].
//!
//! Integrates @timfayz's pretty-printing library, pretty[^2], in order
//! to have general-purpose printing of data structures, and for diffs,
//! diffz[^3].  Last, but not least, for the regex library: the Minimum
//! Viable Zig Regex[^4].
//!
//!
//! [^1]: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/testing/snaptest.zig.
//! [^2]: https://github.com/timfayz/pretty
//! [^3]: https://github.com/ziglibs/diffz
//! [^4]: https://github.com/mnemnion/mvzr

const std = @import("std");
const builtin = @import("builtin");
const pretty = @import("pretty");
const diffz = @import("diffz");
const mvzr = @import("mvzr");
const testing = std.testing;

const assert = std.debug.assert;
const SourceLocation = std.builtin.SourceLocation;

const DiffList = std.ArrayListUnmanaged(diffz.Diff);
const Diff = diffz.Diff;

// Generous limits for user regexen
const UserRegex = mvzr.SizedRegex(128, 16);

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

/// Creates a new Snap using `pretty` formatting.
///
/// For the update logic to work, *must* be formatted as:
///
/// ```
/// try oh.snap(@src(), // This can be on the next line
///     \\Text of the snapshot.
/// ).expectEqual(val);
/// ```
///
/// With the `@src()` on the line before the text, which must be
/// in multi-line format.
pub fn snap(ohsnap: OhSnap, location: SourceLocation, text: []const u8) Snap {
    return Snap{
        .location = location,
        .text = text,
        .ohsnap = ohsnap,
    };
}

// Regex for detecting embedded regexen
const ignore_regex_string = "<\\^[^\n]+?\\$>";
const regex_finder = mvzr.compile(ignore_regex_string).?;

pub const Snap = struct {
    location: SourceLocation,
    text: []const u8,
    ohsnap: OhSnap,

    const allocator = std.testing.allocator;

    /// Compare the snapshot with a pretty-printed string.
    pub fn expectEqual(snapshot: *const Snap, args: anytype) !void {
        const got = try pretty.dump(
            allocator,
            args,
            snapshot.ohsnap.pretty_options,
        );
        defer allocator.free(got);
        try snapshot.diff(got, true);
    }

    /// Compare the snapshot with a .fmt printed string.
    pub fn expectEqualFmt(snapshot: *const Snap, args: anytype) !void {
        const got = try std.fmt.allocPrint(allocator, "{any}", .{args});
        defer allocator.free(got);
        try snapshot.diff(got, true);
    }

    /// Show the snapshot diff without testing
    pub fn show(snapshot: *const Snap, args: anytype) !void {
        const got = try pretty.dump(
            allocator,
            args,
            snapshot.ohsnap.pretty_options,
        );
        defer allocator.free(got);
        try snapshot.diff(got, false);
    }

    /// Show a diff with the .fmt string without testing.
    pub fn showFmt(snapshot: *const Snap, args: anytype) !void {
        const got = try std.fmt.allocPrint(allocator, "{any}", .{args});
        defer allocator.free(got);
        try snapshot.diff(got, false);
    }

    /// Compare the snapshot with a given string.
    pub fn diff(snapshot: *const Snap, got: []const u8, test_it: bool) !void {
        // Check for an update first
        const update_idx = std.mem.indexOf(u8, snapshot.text, "<!update>");
        if (update_idx) |idx| {
            if (idx == 0) {
                const match = regex_finder.match(snapshot.text);
                if (match) |_| {
                    return try patchAndUpdate(snapshot, got);
                } else {
                    return try updateSnap(snapshot, got);
                }
            } else {
                // Probably a user mistake but the diff logic will surface that
            }
        }

        const dmp = diffz{ .diff_timeout = 0 };
        var diffs = try dmp.diff(allocator, snapshot.text, got, false);
        defer diffz.deinitDiffList(allocator, &diffs);
        if (diffDiffers(diffs) or !test_it) {
            try diffz.diffCleanupSemantic(allocator, &diffs);
            // Check if we have a regex in the snapshot
            const match = regex_finder.match(snapshot.text);
            if (match) |_| {
                diffs = try regexFixup(&diffs, snapshot, got);
                if (test_it)
                    if (!diffDiffers(diffs)) return;
            }
            const diff_string = try diffz.diffPrettyFormatXTerm(allocator, diffs);
            defer allocator.free(diff_string);
            const differs = if (test_it) " differs" else "";
            std.debug.print(
                \\Snapshot on line {s}{d}{s}{s}:
                \\
                \\{s}
                \\
            ,
                .{
                    "\x1b[33m",
                    snapshot.location.line + 1,
                    "\x1b[m",
                    differs,
                    diff_string,
                },
            );
            if (test_it) {
                std.debug.print("\n\nTo replace contents, add <!update> as the first line of the snap text.\n", .{});
                return try std.testing.expect(false);
            } else return;
        }
    }

    fn updateSnap(snapshot: *const Snap, got: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();

        // If a src directory exists, use it otherwise use the cwd
        const src_dir = std.fs.cwd().openDir("src", std.fs.Dir.OpenOptions{}) catch std.fs.cwd();
        const file_text =
            try src_dir.readFileAlloc(arena_allocator, snapshot.location.file, 1024 * 1024);
        var file_text_updated = try std.ArrayList(u8).initCapacity(arena_allocator, file_text.len);

        const line_zero_based = snapshot.location.line - 1;
        const range = try snapRange(file_text, line_zero_based);

        const snapshot_prefix = file_text[0..range.start];
        const snapshot_text = file_text[range.start..range.end];
        const snapshot_suffix = file_text[range.end..];

        const indent = getIndent(snapshot_text);

        try file_text_updated.appendSlice(snapshot_prefix);
        {
            var lines = std.mem.splitScalar(u8, got, '\n');
            while (lines.next()) |line| {
                try file_text_updated.writer().print("{s}\\\\{s}\n", .{ indent, line });
            }
        }
        try file_text_updated.appendSlice(snapshot_suffix);

        try src_dir.writeFile(.{
            .sub_path = snapshot.location.file,
            .data = file_text_updated.items,
        });

        std.debug.print("Updated {s}\n", .{snapshot.location.file});
        return error.SnapUpdated;
    }

    /// Find regex matches and modify the diff accordingly.
    fn regexFixup(
        diffs: *DiffList,
        snapshot: *const Snap,
        got: []const u8,
    ) !DiffList {
        defer diffz.deinitDiffList(allocator, diffs);
        var regex_find = regex_finder.iterator(snapshot.text);
        var diffs_idx: usize = 0;
        var snap_idx: usize = 0;
        var got_idx: usize = 0;
        var new_diffs = DiffList{};
        errdefer diffz.deinitDiffList(allocator, &new_diffs);
        const dummy_diff = Diff.init(.equal, "");
        regex_while: while (regex_find.next()) |found| {
            // Find this location in the got string.
            const snap_start = found.start;
            const snap_end = found.end;
            const got_start = diffz.diffIndex(diffs.*, snap_start);
            const got_end = diffz.diffIndex(diffs.*, snap_end);
            // Check if these are identical (use/mention distinction!)
            if (std.mem.eql(u8, found.slice, got[got_start..got_end])) {
                // That's fine then
                continue :regex_while;
            }
            // Trim the angle brackets off the regex.
            const exclude_regex = found.slice[1 .. found.slice.len - 1];
            const maybe_matcher = UserRegex.compile(exclude_regex);
            if (maybe_matcher == null) {
                std.debug.print("Issue with mvzr or regex, hard to say. Regex string: {s}\n", .{exclude_regex});
                continue :regex_while;
            }
            const matcher = maybe_matcher.?;
            const maybe_match = matcher.match(got[got_start..got_end]);
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
                            try new_diffs.append(allocator, dummy_diff);
                        } else {
                            try new_diffs.append(allocator, try dupe(d));
                        }
                    },
                    .insert => {
                        // Are we in the match?
                        got_idx += d.text.len;
                        if (in_got) {
                            // Yes, replace with dummy equal
                            try new_diffs.append(allocator, dummy_diff);
                        } else {
                            try new_diffs.append(allocator, try dupe(d));
                        }
                    },
                    .delete => {
                        snap_idx += d.text.len;
                        // Same deal, are we in the match?
                        if (in_snap) {
                            try new_diffs.append(allocator, dummy_diff);
                        } else {
                            try new_diffs.append(allocator, try dupe(d));
                        }
                    },
                }

                if (got_idx >= got_end and snap_idx >= snap_end) break;
            }
            // Should always mean we have at least two (but we care about
            // having one) diffs rubbed out.
            var formatted = try std.ArrayList(u8).initCapacity(allocator, 10);
            defer formatted.deinit();
            assert(new_diffs.items[diffs_idx].operation == .equal and new_diffs.items[diffs_idx].text.len == 0);
            if (maybe_match) |_| {
                // Decorate with cyan for a match.
                try formatted.appendSlice("\x1b[36m");
                try formatted.appendSlice(got[got_start..got_end]);
                try formatted.appendSlice("\x1b[m");
                new_diffs.items[diffs_idx] = Diff{
                    .operation = .equal,
                    .text = try formatted.toOwnedSlice(),
                };
            } else {
                // Decorate magenta for no match, and make it an insert (hence, error)
                try formatted.appendSlice("\x1b[35m");
                try formatted.appendSlice(got[got_start..got_end]);
                try formatted.appendSlice("\x1b[m");
                new_diffs.items[diffs_idx] = Diff{
                    .operation = .insert,
                    .text = try formatted.toOwnedSlice(),
                };
            }
            diffs_idx += 1;
        } // end regex while
        while (diffs_idx < diffs.items.len) : (diffs_idx += 1) {
            const d = diffs.items[diffs_idx];
            try new_diffs.append(allocator, try dupe(d));
        }
        return new_diffs;
    }

    fn patchAndUpdate(snapshot: *const Snap, got: []const u8) !void {
        const dmp = diffz{ .diff_timeout = 0, .match_threshold = 0.05 };
        var diffs = try dmp.diff(allocator, snapshot.text, got, false);
        defer diffz.deinitDiffList(allocator, &diffs);
        // Very similar to `regexFixup`, but here we clean up the diffed region,
        // then add a paired delete/insert, and use it to patch `got`.
        var regex_find = regex_finder.iterator(snapshot.text);
        var got_idx: usize = 0;
        var new_diffs = DiffList{};
        defer diffz.deinitDiffList(allocator, &new_diffs);
        var new_got = try std.ArrayList(u8).initCapacity(allocator, @max(got.len, snapshot.text.len));
        defer new_got.deinit();
        while (regex_find.next()) |found| {
            // Find this location in the got string.
            const snap_start = found.start;
            const snap_end = found.end;
            const got_start = diffz.diffIndex(diffs, snap_start);
            const got_end = diffz.diffIndex(diffs, snap_end);
            try new_got.appendSlice(got[got_idx..got_start]);
            try new_got.appendSlice(found.slice);
            got_idx = got_end;
        }
        try new_got.appendSlice(got[got_idx..]);
        return try updateSnap(snapshot, new_got.items);
    }

    fn dupe(d: Diff) !Diff {
        return Diff.init(d.operation, try allocator.dupe(u8, d.text));
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

const Range = struct { start: usize, end: usize };

/// Extracts the range of the snapshot. Assumes that the snapshot is formatted as
///
/// ```
/// oh.snap(@src(),
///     \\first line
///     \\second line
/// ).expectEqual(val);
/// ```
///
/// or
///
/// ```
/// oh.snap(
/// @src(),
///     \\first line
///     \\second line
/// ).expectEqual(val);
/// ```
///
/// In the event that a file is modified, we fail the test with a (hopefully informative)
/// error.
fn snapRange(text: []const u8, src_line: u32) !Range {
    var offset: usize = 0;
    var line_number: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
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

    lines = std.mem.splitScalar(u8, text[snap_start..], '\n');
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
    // Change either the snapshot or the struct to make these tests fail
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
        \\          "Snap"
        \\    .is_tuple: bool = false
        ,
    ).expectEqual(@typeInfo(@This()));
}
test "snap regex" {
    const RandomField = struct {
        const RF = @This();
        str: []const u8 = "arglebargle",
        pi: f64 = 3.14159,
        rand: u64,
        xtra: u16 = 1571,
        fn init(rand: u64) RF {
            return RF{ .rand = rand };
        }
    };
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();
    const an_rf = RandomField.init(rand.int(u64));
    const oh = OhSnap{};
    try oh.snap(
        @src(),
        \\ohsnap.test.snap regex.RandomField
        \\  .str: []const u8
        \\    "argle<^\w+?$>gle"
        \\  .pi: f64 = 3.14159e0
        \\  .rand: u64 = <^[0-9]+$>
        \\  .xtra: u16 = 1571
        ,
    ).expectEqual(an_rf);
}

const StampedStruct = struct {
    message: []const u8,
    tag: u64,
    timestamp: isize,
    pub fn init(msg: []const u8, tag: u64) StampedStruct {
        return StampedStruct{
            .message = msg,
            .tag = tag,
            .timestamp = std.time.timestamp(),
        };
    }
};

test "snap with timestamp" {
    const oh = OhSnap{};
    const with_stamp = StampedStruct.init(
        "frobnicate the turbo-encabulator",
        37337,
    );
    try oh.snap(
        @src(),
        \\ohsnap.StampedStruct
        \\  .message: []const u8
        \\    "frobnicate the turbo-<^\w+$>"
        \\  .tag: u64 = 37337
        \\  .timestamp: isize = <^\d+$>
        ,
    ).expectEqual(with_stamp);
}

const CustomStruct = struct {
    foo: u64,
    bar: u66,
    pub fn format(
        self: CustomStruct,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("foo! <<{d}>>, bar! <<{d}>>", .{ self.foo, self.bar });
        _ = fmt;
        _ = options;
    }
};

test "expectEqualFmt" {
    const oh = OhSnap{};
    const foobar = CustomStruct{ .foo = 42, .bar = 23 };
    try oh.snap(
        @src(),
        \\foo! <<42>>, bar! <<23>>
        ,
    ).showFmt(foobar);
}

test "regex match" {
    const oh = OhSnap{};
    try oh.snap(
        @src(),
        \\?mvzr.Match
        \\  .slice: []const u8
        \\    "<^ $\d\.\d{2}$>"
        \\  .start: usize = 0
        \\  .end: usize = 15
        ,
    ).expectEqual(regex_finder.match("<^ $\\d\\.\\d{2}$>"));
}
