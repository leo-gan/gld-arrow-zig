const std = @import("std");
const fb = @import("flatbuf.zig");
const ipc = @import("ipc.zig");
const le = @import("le.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Columnar = model.Columnar;
const Error = model.Error;

pub const PlanPiece = struct {
    buf_id: usize,
    off: usize,
    len: usize,
};

pub const StreamPlan = struct {
    gpa: Allocator,
    // owned template: one full IPC stream produced by the existing writer
    template: []u8,
    // pieces: every non-empty body buffer, absolute offset into that stream
    pieces: []PlanPiece,

    pub fn deinit(self: *StreamPlan) void {
        self.gpa.free(self.template);
        self.gpa.free(self.pieces);
        self.template = &.{};
        self.pieces = &.{};
    }

    pub fn write(self: *const StreamPlan, c: *const Columnar, dest: []u8) Error!usize {
        if (dest.len < self.template.len) return error.Range;
        for (self.pieces) |p| {
            if (c.buf(p.buf_id).len != p.len) return error.Range;
        }
        @memcpy(dest[0..self.template.len], self.template);
        for (self.pieces) |p| {
            @memcpy(dest[p.off..][0..p.len], c.buf(p.buf_id));
        }
        return self.template.len;
    }

    pub fn readPieces(self: *const StreamPlan, raw: []const u8, out: [][]const u8) Error!void {
        if (raw.len != self.template.len) return error.Range;
        if (out.len != self.pieces.len) return error.Range;
        var cursor: usize = 0;
        for (self.pieces) |p| {
            const end = std.math.add(usize, p.off, p.len) catch return error.Syntax;
            if (p.off < cursor or end > raw.len) return error.Syntax;
            if (!std.mem.eql(u8, raw[cursor..p.off], self.template[cursor..p.off])) return error.Syntax;
            cursor = end;
        }
        if (!std.mem.eql(u8, raw[cursor..], self.template[cursor..])) return error.Syntax;
        for (self.pieces, 0..) |p, i| out[i] = raw[p.off..][0..p.len];
    }
};

pub fn buildStreamPlan(gpa: Allocator, c: *const Columnar) Error!StreamPlan {
    try rejectUnsupported(c);
    const template = try ipc.encodeStream(gpa, c);
    errdefer gpa.free(template);
    var list: std.ArrayList(PlanPiece) = .empty;
    errdefer list.deinit(gpa);
    try recordPieces(gpa, c, template, &list);
    const pieces = list.toOwnedSlice(gpa) catch return error.OutOfMemory;
    return .{ .gpa = gpa, .template = template, .pieces = pieces };
}

fn rejectUnsupported(c: *const Columnar) Error!void {
    if (c.codec != null) return error.Compression;
    if (c.dicts.items.len != 0) return error.Schema;
    for (c.batches.items) |batch| {
        if (batch.codec != null) return error.Compression;
    }
    for (c.fields.items) |f| {
        if (f.dict_id >= 0) return error.Schema;
    }
}

const Msg = struct {
    kind: u8,
    body_at: usize,
    body_len: usize,
};

fn nextMessage(raw: []const u8, at: *usize) Error!Msg {
    const i = at.*;
    if (i + 8 > raw.len) return error.EndOfBuffer;
    const word = le.readU32(raw, i) catch return error.EndOfBuffer;
    if (word != 0xFFFFFFFF) return error.Syntax;
    const mlen = le.readU32(raw, i + 4) catch return error.EndOfBuffer;
    if (mlen == 0) return error.Syntax;
    const meta_at = i + 8;
    const meta_end = std.math.add(usize, meta_at, mlen) catch return error.Range;
    if (meta_end > raw.len) return error.Range;
    const r = fb.Reader{ .data = raw[meta_at..meta_end] };
    const table = try r.root();
    const ht = (try r.field(table, 1)) orelse return error.Syntax;
    const kind = try r.u8At(ht);
    var body_len_i: i64 = 0;
    if (try r.field(table, 3)) |p| body_len_i = try r.i64At(p);
    if (body_len_i < 0) return error.Range;
    const body_len: usize = @intCast(body_len_i);
    const body_end = std.math.add(usize, meta_end, body_len) catch return error.Range;
    if (body_end > raw.len) return error.Range;
    at.* = body_end;
    return .{ .kind = kind, .body_at = meta_end, .body_len = body_len };
}

fn expectEos(raw: []const u8, at: usize) Error!void {
    if (at + 8 != raw.len) return error.Syntax;
    const word = le.readU32(raw, at) catch return error.EndOfBuffer;
    const mlen = le.readU32(raw, at + 4) catch return error.EndOfBuffer;
    if (word != 0xFFFFFFFF or mlen != 0) return error.Syntax;
}

fn recordPieces(
    gpa: Allocator,
    c: *const Columnar,
    template: []const u8,
    pieces: *std.ArrayList(PlanPiece),
) Error!void {
    var at: usize = 0;
    const schema = try nextMessage(template, &at);
    if (schema.kind != 1 or schema.body_len != 0) return error.Syntax;
    for (c.batches.items, 0..) |_, bi| {
        const msg = try nextMessage(template, &at);
        if (msg.kind != 3) return error.Syntax;
        try recordBatch(gpa, c, template, msg.body_at, msg.body_len, bi, pieces);
    }
    try expectEos(template, at);
}

fn recordBatch(
    gpa: Allocator,
    c: *const Columnar,
    template: []const u8,
    body_at: usize,
    body_len: usize,
    bi: usize,
    pieces: *std.ArrayList(PlanPiece),
) Error!void {
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(gpa);
    const batch = c.batches.items[bi];
    var col: usize = 0;
    while (col < batch.n_col) : (col += 1) {
        const aid = c.batch_cols.items[batch.col_at + col];
        const f = c.fields.items[c.arrays.items[aid].field];
        try walkArray(gpa, c, f, aid, &order, 0);
    }
    // writePlanned skips empty buffers and aligns each live buffer to 8 bytes.
    var cursor: usize = 0;
    for (order.items) |id| {
        const src = c.buf(id);
        if (src.len == 0) continue;
        cursor = std.mem.alignForward(usize, cursor, 8);
        const end = std.math.add(usize, cursor, src.len) catch return error.Syntax;
        if (end > body_len) return error.Syntax;
        const abs = body_at + cursor;
        if (!std.mem.eql(u8, template[abs..][0..src.len], src)) return error.Syntax;
        try pieces.append(gpa, .{ .buf_id = id, .off = abs, .len = src.len });
        cursor = end;
    }
    if (std.mem.alignForward(usize, cursor, 8) != body_len) return error.Syntax;
}

fn walkArray(
    gpa: Allocator,
    c: *const Columnar,
    f: model.Field,
    aid: usize,
    order: *std.ArrayList(usize),
    depth: usize,
) Error!void {
    if (depth > model.max_depth) return error.Depth;
    const a = c.arrays.items[aid];
    const local = model.localBufs(f);
    var i: usize = 0;
    while (i < local and i < a.n_buf) : (i += 1) {
        try order.append(gpa, c.abufs.items[a.buf_at + i]);
    }
    if (model.isVariadic(f.kind)) {
        while (i < a.n_buf) : (i += 1) {
            try order.append(gpa, c.abufs.items[a.buf_at + i]);
        }
    }
    var ch: usize = 0;
    while (ch < a.n_child and ch < f.n_child) : (ch += 1) {
        const cf = c.fields.items[c.kids.items[f.child_at + ch]];
        const child = c.achilds.items[a.child_at + ch];
        try walkArray(gpa, c, cf, child, order, depth + 1);
    }
}

fn prim(c: *Columnar, name: []const u8, kind: model.Kind, bit_width: i32, unit: u16) Error!usize {
    var f = model.Field{};
    f.name = @intCast(try c.intern(name));
    f.kind = kind;
    f.bit_width = bit_width;
    f.unit = unit;
    f.is_signed = true;
    f.nullable = false;
    return c.addField(f);
}

fn addBool(c: *Columnar, fid: usize, v: bool) Error!usize {
    const bits = [_]u8{if (v) 1 else 0};
    return c.addArray(1, 0, fid, &.{ &.{}, &bits }, &.{});
}

fn addI32(c: *Columnar, fid: usize, v: i32) Error!usize {
    var raw: [4]u8 = undefined;
    std.mem.writeInt(i32, &raw, v, .little);
    return c.addArray(1, 0, fid, &.{ &.{}, &raw }, &.{});
}

fn addI64(c: *Columnar, fid: usize, v: i64) Error!usize {
    var raw: [8]u8 = undefined;
    std.mem.writeInt(i64, &raw, v, .little);
    return c.addArray(1, 0, fid, &.{ &.{}, &raw }, &.{});
}

fn addF64(c: *Columnar, fid: usize, v: f64) Error!usize {
    var raw: [8]u8 = undefined;
    std.mem.writeInt(u64, &raw, @bitCast(v), .little);
    return c.addArray(1, 0, fid, &.{ &.{}, &raw }, &.{});
}

fn addUtf8(c: *Columnar, fid: usize, text: []const u8) Error!usize {
    var offs: [8]u8 = undefined;
    std.mem.writeInt(i32, offs[0..4], 0, .little);
    std.mem.writeInt(i32, offs[4..8], @intCast(text.len), .little);
    return c.addArray(1, 0, fid, &.{ &.{}, &offs, text }, &.{});
}

fn messageRow(gpa: Allocator, n: i32, s0: []const u8, s1: []const u8) Error!Columnar {
    var c = Columnar.init(gpa);
    errdefer c.deinit();
    const f_bool = try prim(&c, "f_bool", .bool, 0, 0);
    const f_int32 = try prim(&c, "f_int32", .int, 32, 0);
    const f_int64 = try prim(&c, "f_int64", .int, 64, 0);
    const f_float64 = try prim(&c, "f_float64", .float, 64, 2);
    const f_string = try prim(&c, "f_string", .utf8, 0, 0);
    const f_bool_2 = try prim(&c, "f_bool_2", .bool, 0, 0);
    const f_int32_2 = try prim(&c, "f_int32_2", .int, 32, 0);
    const f_string_2 = try prim(&c, "f_string_2", .utf8, 0, 0);
    const a_bool = try addBool(&c, f_bool, true);
    const a_int32 = try addI32(&c, f_int32, n);
    const a_int64 = try addI64(&c, f_int64, 99);
    const a_float64 = try addF64(&c, f_float64, 1.5);
    const a_string = try addUtf8(&c, f_string, s0);
    const a_bool_2 = try addBool(&c, f_bool_2, false);
    const a_int32_2 = try addI32(&c, f_int32_2, -7);
    const a_string_2 = try addUtf8(&c, f_string_2, s1);
    const fields = [_]usize{ f_bool, f_int32, f_int64, f_float64, f_string, f_bool_2, f_int32_2, f_string_2 };
    const arrays = [_]usize{ a_bool, a_int32, a_int64, a_float64, a_string, a_bool_2, a_int32_2, a_string_2 };
    for (fields) |id| try c.addTop(id);
    try c.addBatch(1, &arrays, null);
    return c;
}

fn bufferCount(src: *const Columnar) usize {
    var n: usize = 0;
    for (src.abufs.items) |id| {
        if (id + 1 > n) n = id + 1;
    }
    for (src.tensors.items) |t| {
        if (t.data_buf + 1 > n) n = t.data_buf + 1;
    }
    return n;
}

fn cloneColumnar(gpa: Allocator, src: *const Columnar) Error!Columnar {
    var dst = Columnar.init(gpa);
    errdefer dst.deinit();
    dst.string_bytes.appendSlice(gpa, src.string_bytes.items) catch return error.OutOfMemory;
    dst.string_off.appendSlice(gpa, src.string_off.items) catch return error.OutOfMemory;
    dst.string_len.appendSlice(gpa, src.string_len.items) catch return error.OutOfMemory;
    dst.fields.appendSlice(gpa, src.fields.items) catch return error.OutOfMemory;
    dst.kids.appendSlice(gpa, src.kids.items) catch return error.OutOfMemory;
    dst.type_ids.appendSlice(gpa, src.type_ids.items) catch return error.OutOfMemory;
    dst.meta_k.appendSlice(gpa, src.meta_k.items) catch return error.OutOfMemory;
    dst.meta_v.appendSlice(gpa, src.meta_v.items) catch return error.OutOfMemory;
    dst.top.appendSlice(gpa, src.top.items) catch return error.OutOfMemory;
    dst.endian = src.endian;
    dst.features = src.features;
    dst.schema_meta_at = src.schema_meta_at;
    dst.n_schema_meta = src.n_schema_meta;
    dst.codec = src.codec;
    var i: usize = 0;
    const nbuf = bufferCount(src);
    while (i < nbuf) : (i += 1) _ = try dst.addBuf(src.buf(i));
    dst.abufs.appendSlice(gpa, src.abufs.items) catch return error.OutOfMemory;
    dst.achilds.appendSlice(gpa, src.achilds.items) catch return error.OutOfMemory;
    dst.arrays.appendSlice(gpa, src.arrays.items) catch return error.OutOfMemory;
    dst.batch_cols.appendSlice(gpa, src.batch_cols.items) catch return error.OutOfMemory;
    dst.batches.appendSlice(gpa, src.batches.items) catch return error.OutOfMemory;
    dst.dicts.appendSlice(gpa, src.dicts.items) catch return error.OutOfMemory;
    dst.shapes.appendSlice(gpa, src.shapes.items) catch return error.OutOfMemory;
    dst.shape_names.appendSlice(gpa, src.shape_names.items) catch return error.OutOfMemory;
    dst.strides.appendSlice(gpa, src.strides.items) catch return error.OutOfMemory;
    dst.tensors.appendSlice(gpa, src.tensors.items) catch return error.OutOfMemory;
    return dst;
}

fn arrayBufId(c: *const Columnar, array_i: usize, slot: usize) usize {
    const a = c.arrays.items[array_i];
    return c.abufs.items[a.buf_at + slot];
}

fn bufMut(c: *Columnar, id: usize) []u8 {
    const view = c.buf(id);
    const items = c.bytes.items;
    std.debug.assert(@intFromPtr(view.ptr) >= @intFromPtr(items.ptr));
    const start = @intFromPtr(view.ptr) - @intFromPtr(items.ptr);
    std.debug.assert(start + view.len <= items.len);
    return items[start..][0..view.len];
}

test "eight-column row stream plan matches encodeStream" {
    const gpa = std.testing.allocator;
    var c1 = try messageRow(gpa, 42, "hello", "world");
    defer c1.deinit();
    var plan = try buildStreamPlan(gpa, &c1);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 10), plan.pieces.len);

    const enc = try ipc.encodeStream(gpa, &c1);
    defer gpa.free(enc);
    try std.testing.expectEqualSlices(u8, enc, plan.template);
    const dest = try gpa.alloc(u8, plan.template.len);
    defer gpa.free(dest);
    const n = try plan.write(&c1, dest);
    try std.testing.expectEqual(enc.len, n);
    try std.testing.expectEqualSlices(u8, enc, dest[0..n]);

    const outs = try gpa.alloc([]const u8, plan.pieces.len);
    defer gpa.free(outs);
    try plan.readPieces(dest[0..n], outs);
    for (plan.pieces, outs) |p, slice| {
        try std.testing.expectEqual(@intFromPtr(dest.ptr) + p.off, @intFromPtr(slice.ptr));
        try std.testing.expectEqualSlices(u8, c1.buf(p.buf_id), slice);
    }

    var c2 = try cloneColumnar(gpa, &c1);
    defer c2.deinit();
    const i32_id = arrayBufId(&c2, 1, 1);
    const text_id = arrayBufId(&c2, 4, 2);
    try std.testing.expectEqual(@as(usize, 4), c2.buf(i32_id).len);
    try std.testing.expectEqual(@as(usize, 5), c2.buf(text_id).len);
    std.mem.writeInt(i32, bufMut(&c2, i32_id)[0..4], 99, .little);
    bufMut(&c2, text_id)[1] = 'a';
    try std.testing.expectEqual(@as(i32, 42), std.mem.readInt(i32, c1.buf(i32_id)[0..4], .little));
    try std.testing.expectEqualStrings("hello", c1.buf(text_id));
    try std.testing.expectEqualStrings("hallo", c2.buf(text_id));

    const enc2 = try ipc.encodeStream(gpa, &c2);
    defer gpa.free(enc2);
    try std.testing.expect(!std.mem.eql(u8, enc, enc2));
    const n2 = try plan.write(&c2, dest);
    try std.testing.expectEqual(enc2.len, n2);
    try std.testing.expectEqualSlices(u8, enc2, dest[0..n2]);

    try plan.readPieces(dest[0..n2], outs);
    var saw_i32 = false;
    var saw_text = false;
    for (plan.pieces, outs) |p, slice| {
        try std.testing.expectEqual(@intFromPtr(dest.ptr) + p.off, @intFromPtr(slice.ptr));
        try std.testing.expectEqualSlices(u8, c2.buf(p.buf_id), slice);
        if (p.buf_id == i32_id) {
            saw_i32 = true;
            try std.testing.expect(!std.mem.eql(u8, slice, plan.template[p.off..][0..p.len]));
        }
        if (p.buf_id == text_id) {
            saw_text = true;
            try std.testing.expectEqualStrings("hallo", slice);
            try std.testing.expect(!std.mem.eql(u8, slice, plan.template[p.off..][0..p.len]));
        }
    }
    try std.testing.expect(saw_i32);
    try std.testing.expect(saw_text);

    const saved = dest[0];
    dest[0] ^= 0x01;
    try std.testing.expectError(error.Syntax, plan.readPieces(dest[0..n2], outs));
    dest[0] = saved;
    var short: [1]u8 = .{0};
    try std.testing.expectError(error.Range, plan.readPieces(&short, outs));

    var stale = try messageRow(gpa, 42, "hello!", "world");
    defer stale.deinit();
    const hold = try gpa.alloc(u8, plan.template.len);
    defer gpa.free(hold);
    @memset(hold, 0xA5);
    try std.testing.expectError(error.Range, plan.write(&stale, hold));
    try std.testing.expect(std.mem.allEqual(u8, hold, 0xA5));
}

test "stream plan patches every record batch" {
    const gpa = std.testing.allocator;
    var c = Columnar.init(gpa);
    defer c.deinit();
    const fid = try prim(&c, "n", .int, 32, 0);
    var raw0: [4]u8 = undefined;
    var raw1: [4]u8 = undefined;
    std.mem.writeInt(i32, &raw0, 1, .little);
    std.mem.writeInt(i32, &raw1, 2, .little);
    const a0 = try c.addArray(1, 0, fid, &.{ &.{}, &raw0 }, &.{});
    const a1 = try c.addArray(1, 0, fid, &.{ &.{}, &raw1 }, &.{});
    try c.addTop(fid);
    try c.addBatch(1, &.{a0}, null);
    try c.addBatch(1, &.{a1}, null);
    var plan = try buildStreamPlan(gpa, &c);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.pieces.len);
    const enc = try ipc.encodeStream(gpa, &c);
    defer gpa.free(enc);
    const dest = try gpa.alloc(u8, enc.len);
    defer gpa.free(dest);
    const n = try plan.write(&c, dest);
    try std.testing.expectEqualSlices(u8, enc, dest[0..n]);

    var copy = try cloneColumnar(gpa, &c);
    defer copy.deinit();
    std.mem.writeInt(i32, bufMut(&copy, arrayBufId(&copy, 1, 1))[0..4], 9, .little);
    const enc2 = try ipc.encodeStream(gpa, &copy);
    defer gpa.free(enc2);
    const n2 = try plan.write(&copy, dest);
    try std.testing.expectEqualSlices(u8, enc2, dest[0..n2]);
    try std.testing.expect(!std.mem.eql(u8, enc, enc2));
}

test "stream plan rejects codec and dictionary batches" {
    const gpa = std.testing.allocator;
    var c = try messageRow(gpa, 1, "a", "b");
    defer c.deinit();
    c.codec = .lz4;
    try std.testing.expectError(error.Compression, buildStreamPlan(gpa, &c));
    c.codec = null;
    c.batches.items[0].codec = .zstd;
    try std.testing.expectError(error.Compression, buildStreamPlan(gpa, &c));
    c.batches.items[0].codec = null;
    c.fields.items[0].dict_id = 7;
    try std.testing.expectError(error.Schema, buildStreamPlan(gpa, &c));
    c.fields.items[0].dict_id = -1;
    try c.addDict(.{ .id = 7, .array = 0, .is_delta = false, .batch_index = 0 });
    try std.testing.expectError(error.Schema, buildStreamPlan(gpa, &c));
}
