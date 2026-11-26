# 0053. Memory and speed with large photos on iPhone and iPad

Date: 2026-11-26
Status: Accepted. Extends 0048 and 0050.

## Context
Issue #236. Decision 0048 noted that a 60 MP RAW decode is large for an iPhone's memory and that phones might need a lower decode scale while editing. iOS ends an app that passes a memory limit it doesn't publish; the limit depends on the device, and `os_proc_available_memory` reports how much is left before it. In the simulator, a full-size export of the 60 MP Leica M11 sample failed with "The photo couldn't be rendered" (#278).

Measured with the sample and its saved edit (clarity, dehaze, highlights and shadows, a curve, a linear mask, a look and a crop), as the peak footprint above the app's own memory. On an M2, GPU memory counts toward it, as it does on an iPhone. The simulator leaves GPU memory out, so its footprints aren't used here.

| | Peak on an M2 |
|---|---|
| Open and edit at an iPhone canvas's size (1206×1300 pixels) | 1.1 GB |
| Zoomed to 50%, a region the canvas's size | 1.8 GB |
| Zoomed to 70% | 2.6 GB |
| Zoomed to 100% | 3.2 GB |
| Full-size JPEG export | 2.4 GB, of which 1.3 GB stayed after it |

The Fit render is small because it decodes at the canvas's size. A zoomed region is cut from the whole photo decoded at the zoom's scale, and clarity, dehaze and highlights and shadows build their maps from all of it, so its memory grows with the whole photo's pixels at that scale: about 60 bytes per pixel.

The simulator showed two more failures, both with the sample:

- Core Image's newest DNG decoder, `9.dng`, gives no image in the iOS 27 simulator, so every render with the embedded profile failed there, including the export in #278. `8.dng` works.
- The simulator makes no texture wider or taller than 8192 pixels, and the export rendered into one texture the size of the photo, 8391 pixels wide after the sample's crop. iPhones and iPads make textures up to 16384 pixels.

## Decision
- **The photo at Fit is unchanged.** It renders at the canvas's size, including during a slider drag, on every device. Its decode is small enough at any photo size, so no phone gets a lower decode scale for it.
- **Zoom has a memory budget on iPhone and iPad.** A zoomed region may use half the memory `os_proc_available_memory` reports, a quarter under serious or critical thermal pressure. It is decoded at most at the largest scale whose whole-photo decode fits, at 64 bytes per pixel, rounded down to a hundredth. Past that scale the region is enlarged smoothly, not by nearest pixel. The budget is read when a photo opens and after a memory warning, not on every render, so the scale stays put while zoomed. On the Mac, and in the simulator, which reports no limit, zoom renders up to full resolution as before (`RenderBudget`).
- **The cached decode is freed when it isn't needed.** On iPhone and iPad the canvas's renderer clears its cached decode and intermediates when the system warns that memory is low, when the app goes to the background, where iOS ends the apps using the most memory first, and when Edit ends. The photo stays open; the next render decodes it again.
- **Export stays full size.** Its context frees its cached intermediates when each export ends. A photo wider or taller than the device's largest texture renders in as few tiles as fit, sharing the whole-photo maps through the context's cache. Tiles match one whole render to within a level of rounding along their seams (one level in 8 bits, two of 65,535 in 16). A photo that fits one texture, as every photo does on the Mac, renders exactly as before.
- **The embedded profile uses the newest DNG decoder that gives an image.** Where `9.dng` works, as on the Mac, it is still used, so no edit that rendered before renders differently and `processVersion` stays the same.
- **Under thermal pressure renders slow down.** The canvas already runs one render at a time and starts the next from the latest value, so a throttled GPU shows fewer steps of a slider drag rather than falling behind, and the zoom budget halves.

## Consequences
- On an iPhone with little memory free, zooming into a 60 MP photo to 100% shows a region decoded at about 70% and enlarged, softer than on the Mac. With more memory free, it is sharper.
- Returning to Edit, or to the app, decodes the photo again before the first change renders, as opening it does.
- Zoomed regions of an edit with clarity, dehaze or highlights and shadows take seconds to render, on the Mac too, because the maps are built from the whole photo at the zoom's scale. That is #282.
- Memory and speed have not been measured on an iPhone; that needs a device (#238). `MemoryTests` measures the same steps on the Mac and in the simulator (CONTRIBUTING.md).
