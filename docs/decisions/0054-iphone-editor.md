# 0054. The iPhone editor: five tools in native sheets

Date: 2026-11-26
Status: Accepted. Replaces 0048's "Edit on iPhone" and the iPhone inspector sheet (#228).

## Context
Issue #285. Decision 0048 gave the iPhone the Mac's inspector, every card in the Mac's order, in a sheet below the photo (#228). Decision 0051 then made iPad and iPhone serve a mobile workflow: quick edits on the go, detailed editing back on the Mac. A phone showing curves, selective color, lens corrections and transform in a small sheet is a mobile Lightroom, which is the wrong tool for that workflow. Apple Photos, VSCO and Apple Maps show a better shape for the phone: a few focused tools, each in a sheet that leaves the photo in view.

## Decision
- **iPhone only.** The iPhone (`UIDevice.userInterfaceIdiom == .phone`) gets `PhoneEditor` in the iOS app. iPad keeps `PhotoView`, its trailing inspector and its keyboard shortcuts, including in a narrow window.
- **Navigation bar.** The standard Back button, the filename as the title, Share, and a More menu. Compare shows "Original" as the bar's subtitle.
- **More** is a native `Menu`: Undo, Redo and History; Copy Edits and Paste Edits; Compare and Histogram as toggles; and Reset, which reverts the photo as Revert to Original does, without asking, since Undo brings it back. Reset isn't drawn as destructive, so it stays white.
- **Bottom toolbar.** Five `ToolbarItem`s with flexible `ToolbarSpacer`s between them, so each is its own Liquid Glass button: Looks, Light, Color, Finish and Crop. No segmented control or custom bar.
- **Tool sheets.** Looks, Light, Color and Finish each open a sheet with a compact height (212 points: the title and two sliders, with room above the first) and the system's medium height; in landscape only the compact one. The sheet has the tool's name, Reset for that tool's sliders and a close button, with the system's soft scroll edge under that bar. The photo is inset by the sheet's height, measured from its top edge, as the #228 sheet did, so it stays whole above the sheet at both heights, and stays zoomable while the sheet is up. The filmstrip makes way while a sheet is up. Sliders are `AdjustmentSlider`, which is a SwiftUI `Slider` with the inspector's steps and track colors, and render live during a drag through the same path as the inspector.
  - Looks: the imported LUTs and Strength (`LookSection` without its card). There are no built-in looks.
  - Light: Exposure, Contrast, Highlights, Shadows, Whites and Blacks.
  - Color: Temperature, Tint, Saturation and Vibrance.
  - Finish: Grain, Clarity, Sharpness and Vignette, each the amount only. Fade is left out.
- **Sheet colors.** The tool sheets are opaque, not glass, in the system's `tertiarySystemBackground`. In the app's dark interface that is about 18% gray: a step lighter than the 13% canvas, so the sheet stands apart from it, and close to the gray of the inspector cards on the Mac and iPad. The touch tools' sheets (crop, and spot removal and masks from a keyboard) keep the iPad inspector's colors, cards on the canvas gray, and History keeps its own panel's.
- **Histogram.** Turned on from More, it floats in a small container in the same gray as the tool sheets, over the canvas's top-leading corner, 48 points tall rather than the inspector's 84. It is temporary and small, so it may sit over the canvas, as an on-image tool does.
- **Crop** still opens the touch crop tool from #229, with its controls in a sheet and Cancel and Done in the bar, until #287 makes crop a canvas mode.
- **Hidden tools.** Spot removal, masks, the white balance eyedropper and Guided Upright stay in the code and in the recipe but have no control on iPhone. #288 brings them back under More. A keyboard's shortcuts can still open Spot Removal and Masks, so their controls and Done still show when that happens.
- **Model.** `PhoneTool` and `PhoneAdjustment` in `ProofKit` list each tool's sliders and read, write and reset one recipe value each, so they're tested without a view. They write only their own value: curves, HSL and selective color, black and white, noise reduction, masks, spots, lens, transform, crop and the other effects settings are kept as they are. The sheets have no card switches, so moving a slider in a card switched off on the Mac (`switchedOff`) switches that card on first, as choosing a look already did. Nothing about rendering or the recipe format changes.

## Consequences
- An edit made on the Mac with tools the iPhone lacks still renders on the iPhone and survives editing there.
- The iPhone has fewer controls than before: white balance presets, Auto Tone, Texture, Dehaze, the curve and the rest are Mac and iPad only. Those edits render on iPhone but can only be changed elsewhere.
- `PhoneToolSliders` in `ProofUI` is used only by the iPhone. It lives in `ProofUI` because the inspector's track colors are there.
- The filmstrip has no button on iPhone; #286 redesigns the photo viewer with a persistent filmstrip.
