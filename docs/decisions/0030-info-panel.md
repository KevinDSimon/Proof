# 0030. The Info panel and writing descriptions to XMP

Date: 2026-11-12
Status: Accepted

## Context
Issue #151 asked for Get Info, then grew into a panel like Lightroom's Metadata panel: see a photo's file and camera details, and add a title, caption, keywords, creator, copyright and location that other apps read. Lightroom, Capture One and Photomator store these as IPTC Core fields in XMP, and for RAW files in the XMP sidecar. Lightroom lets people edit these fields but not the camera's own values, such as exposure or lens. It changes a RAW file only to correct the capture time, and only when a preference allows it.

Proof never writes to originals (decision 0002), and so far it changed only simple values in sidecars (decision 0022). Title, caption, copyright, creator and keywords are lists in XMP (`rdf:Alt`, `rdf:Seq`, `rdf:Bag`), not simple values.

## Decision
- Browse has an Info panel in the inspector column, shown with View › Show Info (⌘I) or the Info button in the toolbar. It shows the one selected photo and follows the selection. With several photos selected it shows nothing. Multiple selection doesn't show shared or mixed values.
- Edit has an Info card below the histogram, collapsed until opened. ⌘I opens and closes it, and opens the inspector if it is hidden.
- File and capture details are read-only. They come from ImageIO's properties for the original (`PhotoInfo`). The capture time is shown in the offset the camera recorded, or as recorded when there is none.
- Title (`dc:title`), Caption (`dc:description`), Keywords (`dc:subject`), Creator (`dc:creator`), Copyright (`dc:rights`), Sublocation (`Iptc4xmpCore:Location`), City, State or Province and Country (`photoshop:City`, `photoshop:State`, `photoshop:Country`) can be edited (`PhotoDescription`). A field is saved when it is left or Return is pressed.
- They are read from the sidecar when there is one, which takes the place of the photo's own XMP (decision 0005). Without a sidecar they come from the XMP in the photo, then its IPTC, then the camera's Artist and Copyright.
- `XMPSidecar` edits the sidecar as text, as it does for ratings. A list property is replaced as a whole element in Lightroom's layout, so a title in other languages gives way to the one written. A cleared field is removed. After editing, the file is read back. If the description or the rating, flag and label don't read back as intended, nothing is written.
- A new sidecar, whether made for a rating or a description, copies the description from inside the photo, along with the label, since the sidecar hides that XMP in other apps.
- Camera values, including capture time, lens and GPS position, stay read-only.

## Consequences
- Titles, captions, keywords, credits and locations set in Proof show up in Lightroom, Capture One, Photomator and Bridge without an export step.
- Keywords are typed as one comma-separated field. Hierarchical keywords (`lr:hierarchicalSubject`) are neither read nor written, and filtering by keyword isn't possible yet.
- The panel reads the original each time a photo is selected. On a network volume, values appear a moment after the panel.
- Exported files don't carry the description until export (#24) copies it.
