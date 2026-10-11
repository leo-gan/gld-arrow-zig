# Examples

## Nullable integers

`examples/encode_batch.zig` builds an `int32` column `[1, null, 3]`, then
writes an IPC stream, an IPC file, an LZ4 stream, and a Zstd stream.

```bash
zig build example
./zig-out/bin/encode-batch
```

The files land in `temp/`, which is gitignored. The validity bitmap for three
rows with a null in the middle is the byte `0b00000101`. Values are
little-endian `int32`, including a zero in the null slot.

Set `batch.codec` to `.lz4` or `.zstd` before `encodeStream` when the body
should be compressed. The codec is stored on that record batch.

## One generated row

`testdata/schema/message.json` is a JSON Schema object with integer `id` and
string `name`. The generator writes `Message`.

```zig
const Message = @import("generated/Message.zig").Message;

var msg = Message{ .id = 7, .name = try gpa.dupe(u8, "ada") };
defer msg.deinit(gpa);
const raw = try msg.encode(gpa);
defer gpa.free(raw);
var back = try Message.decode(gpa, raw);
defer back.deinit();
```

`tests/use_generated.zig` is that round trip. `Message.decode` keeps `raw`
alive until the struct’s strings have been copied.

## In-memory Flight exchange

```zig
var hs = try arrow.flight.Exchange.handshake(gpa, 9, "ping");
defer hs.deinit(gpa);

var ex = arrow.flight.Exchange.init(gpa);
defer ex.deinit();
const frames = [_]arrow.flight.FlightData{
    .{ .header = "hdr", .body = "body", .meta = "" },
};
const put = try ex.doPut("ticket", &frames);
defer gpa.free(put);
const got = try ex.doGet("ticket");
defer {
    for (got) |*frame| frame.deinit(gpa);
    gpa.free(got);
}
```

`handshake` checks the protobuf by encoding it and decoding it again. `doPut`
stores the frames. `doGet` returns copies. Nothing in this path opens a socket.
