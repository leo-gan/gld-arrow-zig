# Publishing

Zig 0.16 fetches dependencies by URL and content hash. There is no central upload registry. The GitHub release tag is the package. [Zigistry](https://zigistry.dev/) is the public index.

The package key in `build.zig.zon` is `gld_arrow_zig`. The module name is `arrow`. The version is `0.2.0`. Release tags match the Mojo libraries and have no `v` prefix: `0.2.0`.

## Register once

On the GitHub repository page, open the gear next to About, then Topics. Keep the current topics and add `zig-package`:

`arrow` `serializer` `zig` `zig-package`

Zigistry reads that topic and lists the repository within a day after the first release tag exists. The same topic on a program, rather than a library, is `zig`. This repository is a library, so the topic is `zig-package`.

You can set the topics from the command line. This replaces the topic list:

```bash
gh api -X PUT repos/leo-gan/gld-arrow-zig/topics \
  -f 'names[]=arrow' -f 'names[]=serializer' -f 'names[]=zig' -f 'names[]=zig-package'
```

No Zigistry account and no token are required.

## Publish a version

Merge `.github/workflows/publish.yml` to `main` before creating the release.

```bash
git checkout main
git pull
git tag 0.2.0
git push origin 0.2.0
gh release create 0.2.0 --target main --title 0.2.0 --generate-notes
```

The Publish workflow runs `zig build test`, builds a git archive of the tag, and runs `zig fetch` on that archive and on the GitHub tag tarball. The two hashes must match. It then writes the hash into the release notes.

`build.zig.zon` `paths` decides which files enter the hash. The published set is `build.zig`, `build.zig.zon`, `src`, `LICENSE`, and `README.md`.

Check the hash without editing the release:

```bash
bash scripts/publish.sh --dry-run
```

## Install

Copy the hash from the `0.2.0` release notes.

```zig
.dependencies = .{
    .gld_arrow_zig = .{
        .url = "https://github.com/leo-gan/gld-arrow-zig/archive/refs/tags/0.2.0.tar.gz",
        .hash = "<hash from the 0.2.0 release>",
    },
},
```

```zig
const arrow_dep = b.dependency("gld_arrow_zig", .{
    .target = target,
    .optimize = optimize,
});
const arrow = arrow_dep.module("arrow");
```

Or let the compiler fill the hash in:

```bash
zig fetch --save=gld_arrow_zig https://github.com/leo-gan/gld-arrow-zig/archive/refs/tags/0.2.0.tar.gz
```
