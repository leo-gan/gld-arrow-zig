const std = @import("std");
const Message = @import("generated/Message.zig").Message;

test "generated struct encodes and decodes one row" {
    const gpa = std.testing.allocator;
    const name = try gpa.dupe(u8, "ada");
    var msg = Message{ .id = 7, .name = name };
    defer msg.deinit(gpa);
    const raw = try msg.encode(gpa);
    defer gpa.free(raw);
    try std.testing.expectEqual(raw.len, try msg.encodedLen(gpa));
    var back = try Message.decode(gpa, raw);
    defer back.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 7), back.id);
    try std.testing.expectEqualStrings("ada", back.name);
}
