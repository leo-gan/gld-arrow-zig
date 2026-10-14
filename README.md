# gld-arrow-zig

A from-scratch [Apache Arrow](https://arrow.apache.org/docs/format/Columnar.html)
library for [Zig](https://ziglang.org/) 0.16. The import is `arrow`. The code
generator is `gld-arrowgen-zig`.

The runtime is Zig. It links neither libarrow, liblz4, nor libzstd. PyArrow is
a test oracle only. It is not required to encode or decode.

This repository is a standalone library. It is not part of any other project.

Documentation: [Why Arrow](https://leo-gan.github.io/gld-arrow-zig/why-arrow/),
[Instructions](https://leo-gan.github.io/gld-arrow-zig/instructions/),
[Examples](https://leo-gan.github.io/gld-arrow-zig/examples/),
[Techniques](https://leo-gan.github.io/gld-arrow-zig/techniques/),
[Test data](https://leo-gan.github.io/gld-arrow-zig/test-data/).

## Build

Zig 0.16.0:

```bash
git clone https://github.com/leo-gan/gld-arrow-zig.git
cd gld-arrow-zig
zig build test
zig build
```

`zig build` installs `gld-arrowgen-zig` under `zig-out/bin`.

## Depend on a release

```zig
.dependencies = .{
    .gld_arrow_zig = .{
        .url = "https://github.com/leo-gan/gld-arrow-zig/archive/refs/tags/0.2.0.tar.gz",
        .hash = "gld_arrow_zig-0.2.0-9moWMHGMAwD1Yaukj6dXUXAo3I7qNS75mLPTTMvfO162",
    },
},
```

The module name is `arrow`.

## What it reads and writes

| Surface | Behavior |
| --- | --- |
| IPC stream and file | Schema, dictionary batches, record batches, and the file footer. Metadata versions V4 and V5 are accepted. The writer emits V5. |
| Types | Null, bool, signed and unsigned integers 8/16/32/64, float16/32/64, decimal, date, time, timestamp, duration, interval, binary, large binary, string, large string, utf8 view, binary view, fixed-size binary, list, large list, list view, large list view, fixed-size list, struct, map, dense union, sparse union, dictionary, and run-end encoding. |
| Compression | LZ4 frame and Zstd body compression, implemented in Zig. |
| Tensors | Dense tensor messages, plus sparse COO, CSX, and CSF. |
| Flight | Handshake, DoGet, and DoPut protobuf messages, and an in-memory exchange. |
| Schema | JSON Schema objects and Arrow schema JSON. `gld-arrowgen-zig` emits structs with `encodedLen`, `encode`, and `decode`. |

The writer uses little-endian buffers and 8-byte alignment. Two encodes of the
same value match when the options match. Nulls, field order, and schema
metadata are kept.

Uncompressed little-endian record-batch bodies alias the input bytes.
`decodeStream` and `decodeFile` require that buffer to stay alive until
`Columnar.deinit`.

## Layout

`src/arrow.zig` is the public module. `src/model.zig` is the columnar arena.
`src/ipc.zig` is the stream and file codec. `src/tensor.zig` is dense and
sparse tensors. `src/lz4.zig` and `src/zstd.zig` are the compressors.
`src/flight.zig` is the in-memory Flight exchange. `src/schema_load.zig` and
`src/codegen.zig` turn a schema into Zig.

Version `0.2.0` lives in `build.zig.zon` and `src/version.zig`.

## License

MIT. Copyright (c) 2026 Leonid Ganeline.
