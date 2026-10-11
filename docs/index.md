# gld-arrow-zig

gld-arrow-zig is an [Apache Arrow](https://arrow.apache.org/docs/format/Columnar.html)
serializer written in [Zig](https://ziglang.org/) 0.16. The codec and the code
generator are Zig. They link neither libarrow, liblz4, nor libzstd.

<div class="grid cards" markdown="1">

-   __Why Arrow__

    ---

    What a record batch is, and why the schema travels with the buffers.

    [:octicons-arrow-right-24: Read Why Arrow](why-arrow.md)

-   __Instructions__

    ---

    Build with Zig 0.16, encode a batch, generate Zig, and run the tests.

    [:octicons-arrow-right-24: Open Instructions](instructions.md)

-   __Examples__

    ---

    A nullable integer batch, a generated struct, and an in-memory Flight exchange.

    [:octicons-arrow-right-24: See Examples](examples.md)

-   __Techniques__

    ---

    How IPC framing, compression, tensors, and the columnar arena are laid out.

    [:octicons-arrow-right-24: Read Techniques](techniques.md)

-   __Test data__

    ---

    Streams, an IPC file, compression frames, and the schema used for codegen.

    [:octicons-arrow-right-24: Open Test data](test-data.md)

</div>
