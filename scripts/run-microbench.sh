#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
zig build bench -Doptimize=ReleaseFast
./zig-out/bin/arrow-bench
