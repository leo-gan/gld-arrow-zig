const std = @import("std");
const arrow = @import("arrow");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var c = arrow.Columnar.init(gpa);
    defer c.deinit();
    var f = arrow.Field{};
    f.name = @intCast(try c.intern("a"));
    f.kind = .int;
    f.bit_width = 32;
    f.is_signed = true;
    const fid = try c.addField(f);
    try c.addTop(fid);
    const bm = [_]u8{0b00000101};
    var vals: [12]u8 = undefined;
    std.mem.writeInt(i32, vals[0..4], 1, .little);
    std.mem.writeInt(i32, vals[4..8], 0, .little);
    std.mem.writeInt(i32, vals[8..12], 3, .little);
    const arr = try c.addArray(3, 1, fid, &.{ &bm, &vals }, &.{});
    try c.addBatch(3, &.{arr}, null);
    const stream = try arrow.encodeStream(gpa, &c);
    defer gpa.free(stream);
    const file = try arrow.encodeFile(gpa, &c);
    defer gpa.free(file);
    c.batches.items[0].codec = .lz4;
    const lz = try arrow.encodeStream(gpa, &c);
    defer gpa.free(lz);
    c.batches.items[0].codec = .zstd;
    const zs = try arrow.encodeStream(gpa, &c);
    defer gpa.free(zs);
    try std.Io.Dir.cwd().createDirPath(io, "temp");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "temp/oracle-nulls.arrows", .data = stream });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "temp/oracle-nulls.arrow", .data = file });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "temp/oracle-lz4.arrows", .data = lz });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "temp/oracle-zstd.arrows", .data = zs });
    std.debug.print("wrote {d} stream bytes\n", .{stream.len});
}
