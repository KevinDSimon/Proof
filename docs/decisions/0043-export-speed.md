# 0043. Export speed and progress

Date: 2026-11-17
Status: Accepted

## Context
Issue #196: exporting felt slow and gave no feedback. A full-size JPEG of an M11 DNG without an edit took about 1.4 seconds, but the same photo with its edit (clarity, dehaze, highlights and shadows, a curve, a straightened crop and a look) took 416 seconds. Each of those stages alone took 2 to 6 seconds. The canvas renders the same edit at full size in about 5 seconds.

Three causes, measured one at a time on that photo:

- The export's Core Image context didn't cache intermediates. Clarity, dehaze and highlights and shadows each build a small map of the whole photo; Core Image renders a full-size image in parts, and without the cache each part built every map again from the full-size decode. With the cache: 26 seconds.
- Rendering straight into a bitmap added about 4 seconds over rendering into a texture and copying it out: 21 seconds.
- The export decoded at a scale of 0.9999, not 1. The full size of a cropped photo is rounded down to whole pixels, which leaves the scale a hair under 1, and the RAW decoder resamples the whole photo for any scale under 1. At exactly 1: 8.5 seconds, about the same as the canvas's first full-size render.

## Decision
- The export context caches intermediates and runs at low GPU priority, so the canvas's renders go first. The export renders into a texture the size of the file and copies it into the bitmap.
- When the scale an export fits is within a pixel of full size, it decodes at 1. This changes exported pixels slightly: on the M11 photo, the mean difference is 1.6 levels out of 255, and edges are sharper. It is treated as a fix, not as a change to how edits look, so `processVersion` stays the same: the export at 0.9999 was softer than the canvas at full size, and the export is meant to look like the canvas at the same size (decision 0031). Exports of existing edits made again from now on are slightly sharper.
- The export sheet turns into the export's progress when Export is clicked, and File › Export To opens it too. It shows which photo is being exported, a bar and Stop, then how many photos were exported, which failed and why, and Show in Finder, and stays until Done. A render can't report its own progress, so for one photo the bar runs without a value; for several it counts the photos done. The toolbar's progress ring is gone: it was easy to miss and stood still for the whole of a one-photo export.

## Consequences
- One export runs at a time, and the sheet keeps the window busy until it ends. Browsing while a long batch exports is no longer possible; decision 0031's background queue still does the work, off the main thread.
- Stop still takes effect only between photos, because a render can't be stopped once it starts. The sheet says so ("Stopping after this photo…"). Stopping within a photo, and a bar that moves within one, would need the render split into strips.
- `DNGTimingTests` has export timings, for the whole edit and for each stage alone, that run with `PROOF_SAMPLE_DNG`.
