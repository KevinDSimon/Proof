# 0010. Contrast, whites and blacks as one tone lookup

Date: 2026-11-09
Status: Accepted

## Context
Issue #15 adds the Contrast, Whites and Blacks sliders. The tone curve, which comes later, changes the same tones, so the stage should be built so the curve can join it without a second pass over the image. Curves stored as lookups band when a GPU's texture filtering interpolates at low precision, so the lookup has to be read with care.

## Decision
- The three sliders are baked into one lookup per channel of 4096 32-bit float entries, built on the CPU in `ToneLookup` and applied by a custom Metal kernel compiled at run time, as decision 0009 does for highlights and shadows. Today the three channels hold the same curve; the tone curve will give them their own.
- The lookup is indexed by sRGB-encoded values, which spreads its entries evenly from dark to light. The kernel reads the two nearest entries with nearest sampling and interpolates between them itself, in 32-bit float.
- Inside 0 to 1 the curve keeps black and white in place. Outside, where the extended-range decode can reach, it continues in a straight line at the slope of its end instead of clipping.
- Whites and blacks apply first, then contrast. Whites and blacks each add a bump that is zero at both ends and peaks three quarters of the way toward its end. At ±100 the curve's slope never drops below 0.1, so it always rises.
- Contrast turns around middle gray (0.18 in linear light) and doubles or halves the slope there at ±100. It uses a rational curve instead of a power curve: a power curve's slope at black is zero or infinite, which a lookup can't follow without banding. Its slope at black and white is the inverse of its slope at middle gray.
- The curve is applied to red, green and blue separately. The slight rise in saturation that comes with more contrast is intended, as in Lightroom.
- With all three at 0 the stage is skipped, so `processVersion` stays 1. No release has rendered these values, and the format already stored them.

## Consequences
- The tone curve can be added to the same lookup without another kernel or another pass.
- A test runs a float ramp through the kernel at every slider's ends and checks that it matches the CPU to within 1e-4, never falls and never jumps by more than twice the expected step.
- The strengths were chosen by eye on the sample photo. Changing them after a release renders these values needs a new `processVersion`.
