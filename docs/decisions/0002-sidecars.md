# 0002. Edits in sidecars next to originals, ratings read from XMP

Date: 2026-11-07
Status: Accepted

## Context
Photos live in year and month folders on a Synology NAS. Ratings are currently made in Photomator, which writes standard XMP sidecars. Edits must never touch the original files and should follow the photos between devices.

## Decision
- Store each edit in `<original file name>.proof`, a versioned JSON file next to the original.
- Read star ratings and color labels from XMP sidecars, falling back to XMP embedded in the DNG. Do not write ratings in v1.
- Keep thumbnails and folder indexes in a local, disposable cache.

## Consequences
- No catalog or import step: a folder is the library.
- Edits sync wherever the folder syncs, including to a future iPad app.
- Culling stays in Photomator until writing ratings is added; ratings written later must use standard `xmp:Rating` and `xmp:Label` so other apps keep reading them.
