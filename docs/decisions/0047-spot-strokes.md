# 0047. Brush strokes for spot removal

Date: 2026-11-20
Status: Accepted. Extends 0039.

## Context
Issue #197. Spot removal (decision 0039) only placed circles, so a hair, a scratch or a wire took many overlapping circles. The issue asks for a painted stroke filled from a nearby area that can be moved like a circle's source, with Size and Feather working as they do for circles, and existing circle spots rendering exactly as before.

## Decision
- A spot gains `points`, a path as x and y pairs in a flat list, as a mask brush stroke stores it. A spot with two or more points is a stroke; any other is a circle. A stroke covers everything within `radius` of its path. Its `x` and `y` are its first point, and its source is the whole path moved by the offset from `x`, `y` to `sourceX`, `sourceY`. Moving a spot moves its path with it. Circles are written without `points`, so their sidecars don't change.
- A drag on the photo away from every spot paints a stroke; a click still places a circle. A press counts as a drag once the pointer moves 4 points. The stroke takes a point every 2 points on screen. Painting it, and choosing its source, is one undo step.
- While it is painted, a stroke takes from itself, which changes nothing, so painting costs no healing work. When it ends, it takes from beside it, square to the line from its first point to its last, then from the area Proof chooses.
- The source is chosen as a circle's is (`SpotRemoval.bestOffset`, which `bestSource` now calls with a path of one point, with the same arithmetic). The path is resampled to points half a radius apart, at most 48 of them. The surroundings are sampled on rings around each point, leaving out samples that fall on the stroke itself; the inside is sampled in the same way. The candidates are the stroke moved 2.4 and 3.4 radii in 16 directions. Moved along its own length a stroke covers itself, and its roughness rules that out. The measured area is the stroke's bounds plus the farthest candidate's ring, at a scale that keeps it at most 1200 pixels across.
- A stroke renders with the same Clone and Heal steps as a circle. Its mask fades as a circle's does: full within the radius less Feather percent of it, at least one pixel of fade, scaled by Opacity. Heal matches to the pixels from one pixel beyond the stroke's edge, as for a circle. Both masks are drawn on the processor from each pixel's distance to the path, over the stroke's bounds only, at the render's resolution up to 4096 pixels on the long edge, and the last eight are kept.
- The mask brush's raster (decision 0040) isn't reused. It covers the whole photo at a fixed 2048 pixels, which would make a hair at the smallest size about two pixels wide and soft in an export, and it fades on a smoothstep curve where a circle spot fades linearly.
- The overlay draws a stroke as its outline, and its source as the same outline dashed. A press within a stroke's radius of its path selects or moves it.
- Circle spots render as before and no saved edit renders differently, so `processVersion` stays 2. `formatVersion` stays 3, because the field is new rather than renamed.

## Consequences
- Heal matches brightness over a blur of one radius, so along a thin stroke the match follows the light closely, and a stroke across a gradient heals well.
- A stroke longer than 4096 render pixels on its bounds' long edge has its mask drawn at a lower resolution, so its edge is softer in a full-size export.
- A version of Proof from before this renders a stroke as a circle at its first point. It keeps the path when it saves as long as the number of spots stays the same, since `Sidecar` keeps fields it doesn't recognize inside arrays of the same length.
- Spot Removal stays one item in Copy Settings, unticked by default, and carries strokes with circles.
