# 0013. Applying LUTs with strength

Date: 2026-11-10
Status: Accepted

## Context
Issue #22 applies a `.cube` LUT read by `CubeLUT` (see 0012) as step 4 of the render pipeline, blended with the image before it by a strength from 0 to 100%. Proof's pipeline works in linear extended sRGB, while `.cube` files from grading tools expect display-referred values. Core Image's color cube filters take at most 128 entries per side and only a 3D lattice over 0 to 1, but the parser accepts 1D tables, other domains and up to 256 per side.

## Decision
- The stage converts the image from the working space to sRGB with `matchedFromWorkingSpace(to:)`, applies `CIColorCube`, blends with `CIMix`, and converts back with `matchedToWorkingSpace(from:)`. This is what `CIColorCubeWithColorSpace` does, with the blend added in sRGB. Blending in sRGB moves evenly between the two images as they look; blending in linear light would make half strength look closer to the LUT in the shadows.
- Strength is clamped to 0 to 1. Above 1 the blend would extrapolate past the LUT, which clips colors. At 0, and when no LUT is loaded, the stage returns its input unchanged, so the render matches one with no look exactly.
- Values outside 0 to 1 after the conversion to sRGB, which bright highlights from the linear decode reach, take the cube's edge values. The cube's own output values are kept as the file has them, including those outside 0 to 1.
- `PreparedLUT` lays a `CubeLUT` out once, when it is loaded. A 3D table with the standard domain and at most 128 per side is used as it is. Other tables are sampled with straight-line interpolation: 1D tables onto a 65-per-side lattice, other domains onto 0 to 1 at their own size, and larger tables down to 128 per side.
- The renderer takes the `PreparedLUT` beside the recipe. Turning `look.lut` into a loaded LUT belongs to the LUT library (#23).
- `processVersion` stays at 1. No version of Proof could set a look before this change, so no saved edit renders differently.

## Consequences
- A new reference render, `look.png`, covers the stage at 60% strength with a LUT defined in the tests. The other references are unchanged.
- Preparing a 256-per-side table samples about 2 million points, which takes a noticeable moment in a debug build. The library should prepare LUTs off the main thread and keep them.
- Highlights brighter than display white lose their extra range at full strength. A LUT format that expects scene-referred input would need a different stage.
