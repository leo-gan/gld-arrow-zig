# Why Arrow

Apache Arrow stores a column as contiguous buffers plus a schema. An integer
column is a validity bitmap and a packed values buffer. A string column is a
validity bitmap, an offsets buffer, and one byte array. A reader that already
knows the schema can scan a column without parsing a tag on every value.

IPC puts that schema and those buffers in one byte stream. The metadata is a
FlatBuffer. The body is the buffers, each padded to 8 bytes. A file adds a
footer so a reader can find each batch without scanning from the start.

---

## What this library is for

The library is for programs that want to read and write Arrow IPC from Zig
without linking the C++ library. The same module builds record batches, tensor
messages, and the Flight protobuf messages used to describe a get or a put.

A generated struct is a convenience for a flat row whose fields are integers,
booleans, floats, or strings. The columnar API is the one that carries lists,
structs, dictionaries, and the other logical types.

## What stays in the schema

Field names, nullability, nested children, and schema metadata are part of the
schema message. They are not repeated on every row. Dictionary batches are
separate messages so later record batches can store integer codes.

The writer emits metadata version V5. The reader also accepts V4, which is the
version some older writers still write.
