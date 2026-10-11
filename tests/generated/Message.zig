const std = @import("std");
const arrow = @import("arrow");

pub const Message = struct {
    id: i64,
    name: []u8,

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }

    pub fn encodedLen(self: Message, gpa: std.mem.Allocator) !usize {
        const raw = try self.encode(gpa);
        defer gpa.free(raw);
        return raw.len;
    }

    pub fn encode(self: Message, gpa: std.mem.Allocator) ![]u8 {
        var c = arrow.Columnar.init(gpa);
        defer c.deinit();
        const empty: []const u8 = &.{};
        var f0 = arrow.Field{};
        f0.name = @intCast(try c.intern("id"));
        f0.kind = .int;
        f0.nullable = false;
        f0.bit_width = 64;
        f0.is_signed = true;
        f0.unit = 0;
        const id0 = try c.addField(f0);
        try c.addTop(id0);
        var raw0: [8]u8 = undefined;
        std.mem.writeInt(i64, &raw0, @as(i64, @intCast(self.id)), .little);
        const bufs0 = [_][]const u8{ empty, &raw0 };
        const a0 = try c.addArray(1, 0, id0, &bufs0, &[_]usize{});
        var f1 = arrow.Field{};
        f1.name = @intCast(try c.intern("name"));
        f1.kind = .utf8;
        f1.nullable = false;
        f1.bit_width = 0;
        f1.is_signed = true;
        f1.unit = 0;
        const id1 = try c.addField(f1);
        try c.addTop(id1);
        var off1: [8]u8 = undefined;
        std.mem.writeInt(i32, off1[0..4], 0, .little);
        std.mem.writeInt(i32, off1[4..8], @intCast(self.name.len), .little);
        const bufs1 = [_][]const u8{ empty, &off1, self.name };
        const a1 = try c.addArray(1, 0, id1, &bufs1, &[_]usize{});
        try c.addBatch(1, &.{ a0, a1 }, null);
        return try arrow.encodeStream(gpa, &c);
    }

    pub fn decode(gpa: std.mem.Allocator, raw: []const u8) !Message {
        var c = try arrow.decodeStream(gpa, raw);
        defer c.deinit();
        var rows = try arrow.rowsFromBatch(gpa, &c, 0);
        defer rows.deinit();
        const row = rows.rows.items[0];
        var out_value: Message = .{ .id = 0, .name = &[_]u8{} };
        const n0 = rows.child(row, 0);
        out_value.id = @intCast(rows.nodes.items[n0].scalar);
        const n1 = rows.child(row, 1);
        out_value.name = try gpa.dupe(u8, rows.textOf(n1));
        return out_value;
    }
};
