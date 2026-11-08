# 0004. Native macOS window layout with panels beside the photo

Date: 2026-11-08
Status: Accepted

## Context
Apple's guidelines put Liquid Glass in a layer for controls and navigation that floats above content, and say not to use it in the content layer. They also suggest that a photo editor's editing mode shows its own toolbar controls and restores the standard ones when it ends. Photos, Lightroom and Photomator all separate browsing a folder from editing a photo, and none of them shows browsing filters while editing.

Issue #6 adds the first panel, the Folders sidebar, and the rest of Phase 1 and Phase 2 add a filmstrip and an edit inspector. The app should feel like a standard Mac app on the current macOS. On macOS 26 and later, sidebars and toolbars are translucent glass, and apps can extend their content underneath them. A photo editor needs the opposite: the person judges color and tone, so nothing should tint or cover the photo.

## Decision
- The window is built from standard SwiftUI parts: a `NavigationSplitView` sidebar for folders, the window toolbar for the title, filter and controls, and later an `.inspector` panel for edits. Custom views are used only where SwiftUI has none, such as the filmstrip.
- The photo sits centered, with a margin, on a neutral dark gray canvas (13% gray, the same in Display P3 and sRGB). The gray runs to the window edges under the toolbar glass, so the glass has a calm surface to sit on. The photo stays inside the safe area and the app does not use `backgroundExtensionEffect`, so no glass shows the photo's colors. Panels sit beside the photo. Overlays are limited to temporary or on-image tools.
- Browsing and editing become separate modes, following Photos. Browse shows the sidebar, a thumbnail grid, the filter and an Edit button. Edit shows one photo on the dark canvas with a back button, the photo name, an inspector for adjustments, a filmstrip below and a prominent Done button. Return or double-click enters Edit; Done or Esc leaves it. Edit and Done are preferred over Library and Develop tabs because editing is something done to one photo, not a separate place in the app. Until thumbnails exist the app has only the viewing state, so the window uses the dark appearance throughout.
- The sidebar shows saved folders and their subfolders as they are on disk, with photo counts. Proof does not build its own year or month structure.
- The All, 5 Stars and Edited filter is a segmented control in the toolbar and applies to the selected folder, instead of being a sidebar item that would replace the folder selection. Once the modes exist it appears only while browsing.
- The app has one window, like other photo editors, so the sidebar selection and filter belong to it.

## Consequences
- Standard behaviors come for free: hiding the sidebar with ⌃⌘S, resizing columns, keyboard navigation, VoiceOver and the system's appearance.
- Opening the sidebar or inspector makes the photo smaller instead of covering part of it.
- A second window for comparing photos would need its own selection; that is not planned.

## Amendment, 2026-11-08
Trying the modes in issue #38 changed three points. Both modes follow the system appearance instead of Edit switching the window to dark, because switching between light and dark when entering and leaving Edit was jarring. Edit is entered by double-click or Return, without an Edit button, and left with the back button or Esc, without a Done button, because two buttons that do the same thing were redundant. The canvas follows the appearance too: white in light and 13% gray in dark, so the whole window changes together. A white surround makes a photo look darker than on a dark one; that tradeoff was accepted so the app matches the rest of the system.
