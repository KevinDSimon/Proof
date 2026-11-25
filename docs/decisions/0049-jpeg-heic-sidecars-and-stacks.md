# 0049. JPEG and HEIC photos: their sidecars, and stacks with their RAW

Date: 2026-11-25
Status: Accepted. Extends 0005 and 0022.

## Context
Issue #157. Many people shoot JPEG or HEIC, or RAW+JPEG, and want to cull them in Proof. Until now Proof listed only RAW files. Listing JPEG and HEIC raises two questions.

- Sidecar names. Proof writes ratings to `IMG_0042.xmp` (decision 0022). A camera shooting RAW+JPEG writes `IMG_0042.CR3` and `IMG_0042.JPG`, which would share that file, so rating one would rate the other, and neither app nor person can tell whose rating it is. Lightroom, Capture One and Photomator name sidecars this way; Capture One users report exactly this confusion. Lightroom never writes a sidecar for a JPEG: it writes into the JPEG, which Proof never does (decision 0002). darktable and digiKam name sidecars `IMG_0042.JPG.xmp`, which can't collide.
- Showing a pair. Lightroom and Photos show a pair as one photo by default; Capture One and darktable show two. Proof shows folders as they are on disk and doesn't group files, and virtual copies (#137) will need a stack too.

## Decision
- Proof lists RAW, JPEG and HEIC files. PNG and TIFF aren't listed.
- A JPEG or HEIC photo's new sidecar is `IMG_0042.JPG.xmp`. A RAW's stays `IMG_0042.xmp`.
- A JPEG or HEIC photo beside a RAW of the same name, ignoring case, reads only `IMG_0042.JPG.xmp`; `IMG_0042.xmp` belongs to the RAW. A JPEG or HEIC on its own still reads `IMG_0042.xmp`, as decision 0005 says, and writes to it if it is there, so ratings from other apps keep working.
- Photos are ordered by name without the extension, with a RAW before a JPEG or HEIC of the same name, so a pair sits together whatever the extensions.
- A RAW followed by the JPEG or HEIC photos of the same name in one folder is a stack. Open, every photo of a stack is an ordinary tile, with the usual spacing and selection outline. Each carries a stack mark (`square.stack`) in its top-left corner, before the edit pencil; the RAW's also shows how many photos the stack has. Selection, ratings and flags stay per file.
- Stacks start collapsed: only the RAW is shown, with the photos it hides peeking out above it, one layer each up to two, dimmed. Its count badge opens and collapses the stack, as do Open Stack and Collapse Stack in the right-click menu and in VoiceOver's actions. Collapsing selects the RAW in place of any photo it hides. Arrow keys and Select All move through the photos shown, so a collapsed stack's rating, flag and selection apply to the RAW only. Which stacks are open isn't kept between launches.
- Until #239, JPEG and HEIC photos can't be opened in Edit, exported, or have settings copied or pasted. In Edit, reaching one from the filmstrip shows a short explanation in place of the photo and the inspector.

## Consequences
- A RAW and its JPEG keep separate ratings, and other apps that read `<name>.<extension>.xmp` see them. Lightroom, Capture One and Photomator don't read a JPEG's rating from `IMG_0042.JPG.xmp`; Lightroom keeps a JPEG's rating inside the file, which Proof reads when there is no sidecar.
- A JPEG rated in Capture One beside its RAW, with the rating in the shared `IMG_0042.xmp`, shows that rating on the RAW only.
- The stack mark is a third kind of thumbnail badge, beside ratings and flags. It is white on a dark backing like them, with no color.
- The layers are drawn above the photo, not on it; the photo gives up a few points at the top for each, so they stay inside the cell and its selection outline.
- #137 adds virtual copies as stack members.
- Joined tiles and a shared background plate behind an open stack were tried in mockups and dropped: neither left room for the selection outline without drawing on the photo.
- A subtitle such as "4 photos" still counts every file, including those a collapsed stack hides.
