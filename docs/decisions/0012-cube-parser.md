# 0012. Reading .cube LUT files

Date: 2026-11-10
Status: Accepted

## Context
Issue #21 adds a reader for `.cube` files, the LUT format most color tools export. Proof ships no looks of its own, so every LUT comes from a file the person imports, written by tools that follow the format loosely. The reader has to accept what those tools write and explain clearly what is wrong with a file it can't read.

## Decision
- `CubeLUT` in `ProofKit` reads Adobe's Cube LUT Specification 1.0: `TITLE`, `LUT_1D_SIZE`, `LUT_3D_SIZE`, `DOMAIN_MIN` and `DOMAIN_MAX`, then one line of three numbers per entry. In a 3D table red changes fastest, then green, then blue, and the values are kept in that order.
- It also reads DaVinci Resolve's `LUT_1D_INPUT_RANGE` and `LUT_3D_INPUT_RANGE`, which give one minimum and maximum for all three channels.
- Sizes follow the specification: 2 to 65,536 entries for 1D tables, 2 to 256 per side for 3D tables. Common 3D sizes are 17, 33 and 65.
- A file holds either a 1D or a 3D table. Files that hold both, which Resolve can write as a shaper followed by a cube, are rejected.
- It accepts Unix, Windows and classic Mac line breaks, a byte order mark, tabs, comment lines, comments at the end of a value line, and keywords it doesn't know, which the specification says readers skip. Text that isn't UTF-8 is read as Latin-1.
- Values outside 0 to 1 are kept as they are. How they are used is decided when LUTs are applied (#22).
- Anything else fails with a `CubeLUTError` that names the problem and, where there is one, the line: no size, a size out of range, both kinds of table, a repeated keyword, a keyword after the values have started, a line that isn't the right count of finite numbers, the wrong number of entries, a domain whose minimum isn't below its maximum, or a binary file.
- The reader takes text or `Data`. Opening files stays with `FileAccess`.

## Consequences
- Tests cover 3D tables of sizes 17, 33 and 65, 1D tables of several sizes, both domain forms, the tolerated variations and each error.
- Supporting files with a shaper and a cube later means extending `CubeLUT` with an optional 1D table, not a second reader.
- A 256-per-side table holds about 16.8 million entries. Whether the render pipeline accepts sizes that large is decided in #22.
