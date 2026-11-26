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
- **Tool sheets.** Looks, Light, Color and Finish each open a sheet with a compact height (200 points: the title and two sliders) and the system's medium height; in landscape only the compact one. The sheet has the tool's name, Reset for that tool's sliders and a close button. The photo is inset by the sheet's height, measured from its top edge, as the #228 sheet did, so it stays whole above the sheet at both heights, and stays zoomable while the sheet is up. The filmstrip makes way while a sheet is up. Sliders are `AdjustmentSlider`, which is a SwiftUI `Slider` with the inspector's steps and track colors, and render live during a drag through the same path as the inspector.
  - Looks: the imported LUTs and Strength (`LookSection` without its card). There are no built-in looks.
  - Light: Exposure, Contrast, Highlights, Shadows, Whites and Blacks.
  - Color: Temperature, Tint, Saturation and Vibrance.
  - Finish: Grain, Clarity, Sharpness and Vignette, each the amount only. Fade is left out.
- **Sheet colors.** The sheets are opaque, in the Mac and iPad adjustment panel's color (`Color.interfaceBackground`), not glass, so they read as that panel moved below the photo. History's sheet takes the same color.
- **Histogram.** Turned on from More, it floats in a small Liquid Glass container over the photo's top-leading corner. It is temporary and small, so it may sit over the canvas, as an on-image tool does.
- **Crop** still opens the touch crop tool from #229, with its controls in a sheet and Cancel and Done in the bar, until #287 makes crop a canvas mode.
- **Hidden tools.** Spot removal, masks, the white balance eyedropper and Guided Upright stay in the code and in the recipe but have no control on iPhone. #288 brings them back under More. A keyboard's shortcuts can still open Spot Removal and Masks, so their controls and Done still show when that happens.
- **Model.** `PhoneTool` and `PhoneAdjustment` in `ProofKit` list each tool's sliders and read, write and reset one recipe value each, so they're tested without a view. They write only their own value: curves, HSL and selective color, black and white, noise reduction, masks, spots, lens, transform, crop and the other effects settings are kept as they are. The sheets have no card switches, so moving a slider in a card switched off on the Mac (`switchedOff`) switches that card on first, as choosing a look already did. Nothing about rendering or the recipe format changes.

## Consequences
- An edit made on the Mac with tools the iPhone lacks still renders on the iPhone and survives editing there.
- The iPhone has fewer controls than before: white balance presets, Auto Tone, Texture, Dehaze, the curve and the rest are Mac and iPad only. Those edits render on iPhone but can only be changed elsewhere.
- `PhoneToolSliders` in `ProofUI` is used only by the iPhone. It lives in `ProofUI` because the inspector's track colors are there.
- The filmstrip has no button on iPhone; #286 redesigns the photo viewer with a persistent filmstrip.
