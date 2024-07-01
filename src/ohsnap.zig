const std = @import("std");
const Fluent = @import("Fluent");
const pretty = @import("pretty");
const testing = std.testing;

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

test "fluent integration" {
    var iter = Fluent.match("[abc]", "abdabqccf");
    while (iter.next()) |m| {
        std.debug.print("{s}\n", .{m});
    }
}

test "pretty integration" {
    const alloc = std.testing.allocator;
    const dumped = try pretty.dump(alloc, .{ 1, 2, 3 }, .{});
    defer alloc.free(dumped);
    std.debug.print("{s}\n", .{dumped});
}
