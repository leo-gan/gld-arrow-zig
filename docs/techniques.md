# Techniques

## Framing

Each IPC message starts with `0xFFFFFFFF` and a little-endian `u32` metadata
length. Metadata is padded with zeros so the body starts at a multiple of 8.
The stream ends with `0xFFFFFFFF` and a length of 0. A reader also accepts a
legacy message whose first word is the metadata length.

A file is `ARROW1`, two zero bytes, the messages, the footer, a `u32` footer
size, and `ARROW1` again. Each footer block records the message offset, the
metadata length including its 8-byte prefix, and the body length.

The FlatBuffer `version` field uses enum 3 for metadata V4 and enum 4 for V5.
The writer always stores 4. If the field is absent, the reader treats the
message as V5, which is the FlatBuffers default.

## Buffers

The writer walks each array, records buffer ids, then assigns body offsets in
one pass. It does not build a second copy of the body before the output
allocation. Empty buffers occupy a metadata slot and zero body bytes. A
non-empty buffer is aligned to 8. The output allocation is sized once, with
eight spare bytes so the end-of-stream word does not grow the buffer.

On Linux, a body of at least 256 KiB is allocated on a 2 MiB boundary.
`MADV_HUGEPAGE` and `MADV_POPULATE_WRITE` run before the copy, so the fill
faults huge pages instead of one 4 KiB page at a time. Smaller batches use the
ordinary allocator.

`decodeStream` parses metadata into node lengths, null counts, and buffer
spans. For an uncompressed little-endian batch it stores the body slice and
points each buffer at an offset inside it. Compressed batches are inflated
into `Columnar.bytes`. When the schema endianness is not little, the fixed-width
values buffer is byte-swapped into owned memory.

## Compression

LZ4 uses the frame format. Zstd reading covers the blocks in the checked-in
frames, including Huffman and FSE. Zstd writing emits raw blocks and RLE
blocks, which a standard Zstd reader accepts. A compressed IPC buffer is an
`i64` uncompressed length followed by the payload. A length of `-1` means the
payload is stored uncompressed because compression did not shrink it.

## Types and nesting

Field kinds use the Arrow type union values. Nested arrays are children of the
parent field. Lists, structs, maps, unions, and run-end encoded arrays carry
their child arrays in the same depth-first order the IPC node list uses.
Dictionary-encoded columns store index buffers in the record batch and value
buffers in a dictionary batch. A later delta is kept, and lookup uses the
latest non-delta dictionary for that id.

`rowsFromBatch` projects one batch into scalars, strings, lists, structs,
maps, and dictionary values. It is the reader behind generated `decode`. It
does not rebuild views, decimals wider than eight bytes, unions, or run-end
arrays as Zig values. Those columns remain available through `arrayBuf`.

## Tensors

A dense tensor message carries the type, the shape, optional strides, and one
data buffer. Sparse tensors add index buffers. `Tensor.sparse` is 1 for COO,
2 for CSX, and 3 for CSF. `encodeTensorStream` writes a stream whose first
message is the tensor. `decodeStream` accepts that stream.

## Flight messages

Handshake, FlightData, and PutResult are encoded as protobuf by hand. Field
numbers and wire types follow the Flight definitions used for those three
messages. `Exchange` is a list of tickets and frames in the process heap.
`doPut` returns the encoded `PutResult`. `doGet` finds the ticket and
duplicates the frames.

## Microbench

`benches/bench.zig` builds 100_000 rows: an `i64` id and a 16-byte UTF-8 name.
It times 80 calls to `encodeStream` and 80 calls to `decodeStream` after one
warmup. The stream is 2,800,432 bytes. `scripts/run-microbench.sh` builds it
with `-Doptimize=ReleaseFast` and prints `us/op`.

On the machine used for the 2026-10-11 pass, encode moved from about 1255 µs/op
to about 290 µs/op. Decode moved from about 573 µs/op to about 0.4 µs/op
because the body is no longer copied. The decode figure is the time to build
the columnar description. Reading every value still touches the original
stream. The numbers are one Linux process, not a comparison with other Arrow
libraries.
