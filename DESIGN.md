# Apache Arrow for Zig (`gld-arrow-zig`)

| Field | Value |
| --- | --- |
| **Document title** | Apache Arrow serializer for Zig |
| **Author** | Leonid Ganeline |
| **Date** | 2026-10-11 |
| **Status** | Implemented (0.2.0) |
| **Module** | `arrow` |
| **CLI** | `gld-arrowgen-zig` |
| **License** | MIT, Copyright (c) 2026 Leonid Ganeline |
| **Language** | Zig 0.16.0 |
| **Spec target** | Arrow IPC stream and file, logical types through Arrow 25, tensor messages, and the Flight protobuf messages used by Handshake, DoGet, and DoPut |

## Goals

1. Read IPC metadata versions V4 and V5. Write V5. Accept a legacy metadata length word and the continuation word `0xFFFFFFFF`.
2. Write little-endian buffers aligned to 8 bytes. Two encodes with the same options are the same bytes.
3. Cover the logical types listed in the README, including views, list views, decimals, unions, dictionaries, and run-end encoding.
4. Implement LZ4 frame and Zstd in Zig, with a 64 MiB cap on a compressed body.
5. Read and write dense tensors and sparse COO, CSX, and CSF tensors.
6. Encode and decode Flight Handshake, FlightData, and PutResult messages, and move them through an in-memory `Exchange`.
7. Load a JSON Schema object or an Arrow schema JSON document. `gld-arrowgen-zig` emits a Zig struct with `encodedLen`, `encode`, and `decode`.
8. Link neither libarrow, liblz4, nor libzstd.

## Non-goals

- Sockets, HTTP/2, HPACK, or a Flight service process. `Exchange` keeps frames in process memory.
- The Arrow C Data Interface.
- A Zstd writer that emits Huffman or FSE blocks. The writer emits raw and RLE blocks. The reader accepts the fuller frame set exercised by `testdata/golden`.
- Merging dictionary deltas. A delta batch is stored. Lookup prefers the latest non-delta dictionary for that id.
- Generated Zig for nested list, view, union, run-end, or wide-decimal columns. Those types round-trip as columnar buffers. The generator emits flat scalar fields.

## Layout

```text
src/arrow.zig        public module arrow
src/model.zig        fields, arrays, batches, buffers, tensors
src/flatbuf.zig      FlatBuffers reader and backward builder
src/schema_fb.zig    schema and record-batch tables
src/ipc.zig          stream, file, footer
src/tensor.zig       dense and sparse tensor messages
src/lz4.zig          LZ4 frame
src/zstd.zig         Zstd frame
src/flight.zig       Handshake, DoPut, DoGet, in-memory exchange
src/json.zig         JSON values for schemas
src/schema_load.zig  JSON Schema and Arrow schema JSON
src/rows.zig         one batch as a tree of scalars and strings
src/codegen.zig      Zig struct emitter
src/main.zig         gld-arrowgen-zig
src/version.zig      package version string
```

## IPC

A message is a continuation `0xFFFFFFFF`, a little-endian metadata length, that
many metadata bytes padded to 8, then the body. The end of a stream is a
continuation followed by length 0. A file starts with `ARROW1` and two zero
bytes, then messages, a footer FlatBuffer padded to 8, the footer size, and a
trailing `ARROW1`.

A footer block is 24 bytes: body offset, metadata length (the 8-byte prefix
plus the padded metadata), four pad bytes, and body length. The metadata
version enum on the wire is 3 for V4 and 4 for V5. A missing version field is
read as V5, because that is the FlatBuffers default.

Buffer offsets in a record batch are relative to the body. Empty buffers take
no bytes. Every non-empty buffer starts on an 8-byte boundary. A compressed
buffer starts with an `i64` uncompressed length, then the payload. Length `-1`
means the following bytes are already raw. Codec 0 is LZ4 frame. Codec 1 is
Zstd. Feature bit 2 is set when a batch carries a codec.

## Columnar arena

`Columnar` owns names, fields, arrays, and buffers. `addBuf` copies bytes into
one array. `decodeStream` of an uncompressed little-endian batch does not copy
the body. Each buffer view points into a slice stored on `borrows`. The caller
keeps the IPC bytes alive until `deinit`. Compressed bodies and big-endian
fixed-width value buffers are still copied. Big-endian support swaps the
fixed-width values buffer when the schema endianness is not little. The
checked-in records are little-endian.

Depth of nested fields is capped at 64.

## Tensors

`encodeTensorStream` writes one tensor message. Sparse index 1 is COO, 2 is
CSX, and 3 is CSF. The dense value buffer and the sparse index buffers use the
same 8-byte body alignment as record batches.

## Flight

`Exchange.handshake` round-trips a protocol version (`uint64`) and a payload.
`doPut` stores `FlightData` frames under a ticket and returns a `PutResult`.
`doGet` copies those frames back. There is no network listener.

## Schema and codegen

A JSON object with `properties` is read as JSON Schema. A JSON object with
`fields` and no `properties` is read as Arrow schema JSON. `gld-arrowgen-zig
--schema FILE --out DIR` writes one Zig file. The type name is the schema
`title`, or the schema metadata key `title`, or `Root`.

Generated `encode` builds one record batch with one row. Generated `decode`
reads row 0 through `rowsFromBatch`. String and binary fields are duplicated
with the caller’s allocator. `deinit` frees those slices.

## Speed

ReleaseFast, one process, 80 iterations, 100_000 rows, one `i64` column and one
16-byte string column, IPC stream of 2,800,432 bytes:

| | Encode | Decode |
| --- | --- | --- |
| Before the copy and page-fault work | 1246.5–1263.5 µs/op | 570.1–576.7 µs/op |
| After | 282.8–300.4 µs/op | 0.3–0.4 µs/op |

The encode path plans buffer offsets, writes the FlatBuffer, then copies each
buffer once into a 2 MiB-aligned allocation. On Linux that allocation is advised
`MADV_HUGEPAGE` and `MADV_POPULATE_WRITE` before the copy. The decode path
parses the metadata and records views. A later scan of the values reads the
original stream. These timings are one machine on 2026-10-11. They are not a
cross-language ranking.

## Testing

`zig build test` runs the module tests, the CLI module, and
`tests/use_generated.zig`. Record batches with nulls, dictionaries, lists,
structs, LZ4, Zstd, an IPC footer, and dense and sparse tensors are covered.
PyArrow-produced streams in `testdata/golden` are decoded in process. PyArrow
itself is not a build dependency and is not installed in CI.
