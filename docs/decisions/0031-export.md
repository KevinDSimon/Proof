# 0031. Export

Date: 2026-11-12
Status: Accepted

## Context
Issue #24 asked for JPEG, HEIC and TIFF export with a size, quality and color space, keeping EXIF and the rating, and for exporting several photos in the background. Photos exported from Proof go to two places: a phone or social media, where small sRGB or Display P3 files are wanted, and printing, where labs want large sRGB JPEGs and fine-art printers want 16-bit TIFFs in a wider color space at a set print size.

Lightroom's export window has about nine sections and saved presets. A first draft for Proof had three presets (Phone, Social, Print). Presets hide the settings behind names that don't say what the file will be, and need a way to manage them.

## Decision
- File › Export… (⇧⌘E) and the right-click menu export the selected photos. One sheet shows four groups, with no presets: format (JPEG, HEIC or TIFF, with a quality slider for JPEG and HEIC), size (Original, or Long Edge in px, in or cm, with a resolution in ppi for in and cm), color space (sRGB, Display P3 or Adobe RGB) and a Remove Location switch. The sheet remembers the last settings (`ExportSettings`, stored as JSON in user defaults), which gives most of what presets would.
- A long edge never enlarges a photo. The resolution is written into every file, so a print size prints at that size.
- TIFF is 16 bits per channel and uncompressed. JPEG and HEIC are 8 bits. No file has an alpha channel.
- `RAWRenderer.export` decodes the file on its own at the scale that fits the size asked for, as the canvas does, and applies the same `RAWRenderer.apply` graph, so an export looks like the canvas at that size. The decoder's scale lands within a pixel or so of the size; a Lanczos resample makes it exact.
- The file keeps the original's Exif, Exif aux, TIFF and GPS properties, with the orientation set to upright and the pixel size and Exif color space updated. DNG tags and maker notes are left out. The rating and description (decision 0030) are written as IPTC, which ImageIO also writes as XMP (`xmp:Rating`, `dc:title`, `dc:description` and so on). Remove Location leaves out the GPS position and the description's sublocation, city, state and country.
- Files are named after the photo. When a file of that name exists, "-2", "-3" and so on are added, so nothing is overwritten.
- `ExportQueue` exports one photo at a time with a `RAWRenderer` of its own, so a full-size render never holds up the canvas and only one full-size render is in GPU memory. Each photo uses the edit Proof has in memory when Export is clicked, or its sidecar's, read before the first render. Inspector cards switched off to compare don't affect the export. Exports started while others run join the queue.
- The toolbar shows a progress ring while the queue runs, and a checkmark or a warning when it ends. Its popover shows progress and Stop Export, then how many photos were exported, which failed and why, and Show in Finder. Stop takes effect after the photo being exported.

## Consequences
- A full-size export of a 60 MP DNG renders in about 1.5–2.5 seconds on an M2, plus encoding; a 2048-pixel export in under one second.
- The export folder is chosen each time. Saved destinations are #162.
- There is no output sharpening, watermark, renaming or file-size limit. AirDrop and the Share menu are separate work.
- Exported HEIC files are 8-bit. 10-bit HEIC would keep more of Display P3's range but is not read everywhere.
