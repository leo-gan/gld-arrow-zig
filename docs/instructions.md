# Instructions

These steps assume a Linux machine and Zig 0.16.0. The module name is `arrow`.
The package version in `build.zig.zon` and `src/version.zig` is `0.2.0`.

## Build this repository

```bash
git clone https://github.com/leo-gan/gld-arrow-zig.git
cd gld-arrow-zig
zig build test
zig build
```

`zig build test` compiles `src/arrow.zig`, the `gld-arrowgen-zig` module, and
`tests/use_generated.zig`. `zig build` installs `zig-out/bin/gld-arrowgen-zig`.

| Command | What it runs |
| --- | --- |
| `zig build test` | Unit tests, IPC round trips, tensors, Flight, and the generated `Message` struct. |
| `zig build bench -Doptimize=ReleaseFast` | Builds `zig-out/bin/arrow-bench`. |
| `scripts/run-microbench.sh` | Builds that binary and prints microseconds per encode and decode. |
| `zig build example` | Builds `zig-out/bin/encode-batch`, which writes sample streams under `temp/`. |

A local `.env` file is gitignored. Do not commit it. This library does not
read that file.

## Encode a batch

```zig
const std = @import("std");
const arrow = @import("arrow");

pub fn main(init: std.process.Init) !void {
    var c = arrow.Columnar.init(init.gpa);
    defer c.deinit();
    var f = arrow.Field{};
    f.name = @intCast(try c.intern("a"));
    f.kind = .int;
    f.bit_width = 32;
    f.is_signed = true;
    const fid = try c.addField(f);
    try c.addTop(fid);
    const vals = [_]u8{ 1, 0, 0, 0 };
    const arr = try c.addArray(1, 0, fid, &.{ &.{}, &vals }, &.{});
    try c.addBatch(1, &.{arr}, null);
    const raw = try arrow.encodeStream(init.gpa, &c);
    defer init.gpa.free(raw);
    var back = try arrow.decodeStream(init.gpa, raw);
    defer back.deinit();
}
```

`decodeStream` and `decodeFile` keep uncompressed little-endian bodies as views
into `raw`. Free `raw` only after `back.deinit()`. `encodeStream` returns a
new slice. Free that slice with the same allocator.

Wire the module when you compile a file outside `build.zig`:

```bash
zig build-exe -ODebug --dep arrow -Mroot=examples/encode_batch.zig -Marrow=src/arrow.zig
```

From another package, depend on `gld_arrow_zig` and import the module `arrow`.

## Generate Zig

```bash
zig build run -- --schema testdata/schema/message.json --out tests/generated
```

The command reads JSON Schema or Arrow schema JSON. It also accepts an IPC
stream or file whose schema metadata contains `title`. The output file is
named after the struct. Compile it with `--dep arrow` and import
`generated/Message.zig` as `.Message`.

Generated methods are `encodedLen`, `encode`, `decode`, and `deinit`.
`encodedLen` encodes once and returns the byte count. String fields are
`[]u8` owned by the caller.
