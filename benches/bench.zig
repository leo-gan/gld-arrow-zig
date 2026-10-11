const std = @import("std");
const arrow = @import("arrow");

const rows: usize = 100_000;
const iters: usize = 80;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var c = try sample(gpa);
    defer c.deinit();
    var warm = try arrow.encodeStream(gpa, &c);
    defer gpa.free(warm);
    var decoded = try arrow.decodeStream(gpa, warm);
    decoded.deinit();

    var encode_ns: i96 = 0;
    var last: []u8 = warm;
    warm = &.{};
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const raw = try arrow.encodeStream(gpa, &c);
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        encode_ns += t0.durationTo(t1).raw.nanoseconds;
        if (i + 1 == iters) last = raw else gpa.free(raw);
    }
    defer gpa.free(last);

    var decode_ns: i96 = 0;
    i = 0;
    while (i < iters) : (i += 1) {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        var back = try arrow.decodeStream(gpa, last);
        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        decode_ns += t0.durationTo(t1).raw.nanoseconds;
        back.deinit();
    }
    const encode_avg = @divTrunc(encode_ns, iters);
    const decode_avg = @divTrunc(decode_ns, iters);
    std.debug.print("rows {d}\n", .{rows});
    std.debug.print("bytes {d}\n", .{last.len});
    std.debug.print("encode {d}.{d} us/op\n", .{ @divTrunc(encode_avg, 1000), @divTrunc(@mod(encode_avg, 1000), 100) });
    std.debug.print("decode {d}.{d} us/op\n", .{ @divTrunc(decode_avg, 1000), @divTrunc(@mod(decode_avg, 1000), 100) });
}

fn sample(gpa: std.mem.Allocator) !arrow.Columnar {
    var c = arrow.Columnar.init(gpa);
    errdefer c.deinit();
    var fi = arrow.Field{};
    fi.name = @intCast(try c.intern("id"));
    fi.kind = .int;
    fi.bit_width = 64;
    fi.is_signed = true;
    fi.nullable = false;
    const idf = try c.addField(fi);
    try c.addTop(idf);
    var fs = arrow.Field{};
    fs.name = @intCast(try c.intern("name"));
    fs.kind = .utf8;
    fs.nullable = false;
    const sf = try c.addField(fs);
    try c.addTop(sf);

    const ids = try gpa.alloc(u8, rows * 8);
    errdefer gpa.free(ids);
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        std.mem.writeInt(i64, ids[i * 8 ..][0..8], @intCast(i), .little);
    }
    const id_arr = try c.addArray(@intCast(rows), 0, idf, &.{ &.{}, ids }, &.{});
    gpa.free(ids);

    const offs = try gpa.alloc(u8, (rows + 1) * 4);
    errdefer gpa.free(offs);
    const text = try gpa.alloc(u8, rows * 16);
    errdefer gpa.free(text);
    i = 0;
    while (i < rows) : (i += 1) {
        std.mem.writeInt(i32, offs[i * 4 ..][0..4], @intCast(i * 16), .little);
        const slot = text[i * 16 ..][0..16];
        @memset(slot, 'a');
        slot[0] = @intCast('a' + (i % 26));
    }
    std.mem.writeInt(i32, offs[rows * 4 ..][0..4], @intCast(rows * 16), .little);
    const s_arr = try c.addArray(@intCast(rows), 0, sf, &.{ &.{}, offs, text }, &.{});
    gpa.free(offs);
    gpa.free(text);
    try c.addBatch(@intCast(rows), &.{ id_arr, s_arr }, null);
    return c;
}
