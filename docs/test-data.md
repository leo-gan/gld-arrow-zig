# Test data

The tests read byte files under `testdata/` and build a few batches in memory.

## IPC records

These files were written by PyArrow 25 so the decoder can be checked against
another implementation. The test process does not launch PyArrow.

| File | What a passing run checks |
| --- | --- |
| `testdata/golden/pa-basic.arrows` | Stream with nullable int32, utf8, bool, and float64, including a null and a NaN. |
| `testdata/golden/pa-basic.arrow` | The same batch as a file. The footer reports one batch and four fields. |
| `testdata/golden/pa-list.arrows` | A list column. |
| `testdata/golden/pa-struct.arrows` | A struct column. |
| `testdata/golden/pa-dict.arrows` | A dictionary-encoded column and its dictionary batch. |
| `testdata/golden/pa-map.arrows` | A map column. The test checks that the stream decodes. |
| `testdata/golden/pa-union.arrows` | Dense union of `int32` and `utf8`. The test checks that the stream decodes. |
| `testdata/golden/pa-ree.arrows` | Run-end encoded `int32`. The test checks that the stream decodes. |
| `testdata/golden/pa-view.arrows` | String view. The test checks that the stream decodes. |
| `testdata/golden/pa-lview.arrows` | List view of `int32`. The test checks that the stream decodes. |
| `testdata/golden/pa-dec.arrows` | Decimal128. Precision 10 and scale 2 are checked. |
| `testdata/golden/pa-d32.arrows` | `decimal32(5, 2)`. The test checks that the stream decodes. |
| `testdata/golden/pa-d256.arrows` | `decimal256(10, 2)`. The test checks that the stream decodes. |
| `testdata/golden/pa-time.arrows` | `date32`, `timestamp[us, UTC]`, and `duration[ms]`. The test checks that the stream decodes. |
| `testdata/golden/pa-interval.arrows` | Interval. The test checks that the stream decodes. |
| `testdata/golden/pa-fsb.arrows` | Fixed-size binary. The kind is checked. |
| `testdata/golden/tensor.arrows` | A dense tensor message. One value is read back. |

`src/roundtrip_test.zig` also builds batches in memory: nulls, a dictionary, a
list, a struct, LZ4, Zstd, and sparse COO, CSX, and CSF tensors. Those checks
encode with this library and decode with this library. `src/ipc.zig` checks
that two encodes of the nullable integer batch are byte-identical, and that
the file footer version is V5.

## Compression frames

| File | What a passing run checks |
| --- | --- |
| `testdata/golden/lz4-hello.lz4` | An LZ4 frame decompresses to `hello hello hello hello hello`. |
| `testdata/golden/zstd-*.zst` | Zstd frames: empty, short literals, repeats, a content checksum, a skippable frame, and mixed blocks. `zstd-dict.zst` returns `error.Compression` because its dictionary id is not zero. |

The IPC LZ4 and Zstd checks use batches this library compresses. They confirm
the codec id, the feature bit, and a value after inflate.

## Schema

| File | What it generates |
| --- | --- |
| `testdata/schema/message.json` | `Message`, with `id: i64` and `name: []u8`. |

`tests/generated/Message.zig` is the checked-in output.
`tests/use_generated.zig` fills one row, checks `encodedLen` against
`encode`, and decodes it. Regenerate with:

```bash
zig build run -- --schema testdata/schema/message.json --out tests/generated
```
