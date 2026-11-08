# 0004. Native macOS window layout with panels beside the photo

Date: 2026-11-08
Status: Accepted

## Context
Issue #6 adds the first panel, the Folders sidebar, and the rest of Phase 1 and Phase 2 add a filmstrip and an edit inspector. The app should feel like a standard Mac app on the current macOS. On macOS 26 and later, sidebars and toolbars are translucent glass, and apps can extend their content underneath them. A photo editor needs the opposite: the person judges color and tone, so nothing should tint or cover the photo.

## Decision
- The window is built from standard SwiftUI parts: a `NavigationSplitView` sidebar for folders, the window toolbar for the title, filter and controls, and later an `.inspector` panel for edits. Custom views are used only where SwiftUI has none, such as the filmstrip.
- Panels sit beside the photo. The canvas stays inside the safe area and does not use `backgroundExtensionEffect`, so no glass shows the photo's colors. Overlays are limited to temporary or on-image tools.
- The sidebar shows saved folders and their subfolders as they are on disk, with photo counts. Proof does not build its own year or month structure.
- The All, 5 Stars and Edited filter is a segmented control in the toolbar and applies to the selected folder, instead of being a sidebar item that would replace the folder selection.
- The app has one window, like other photo editors, so the sidebar selection and filter belong to it.

## Consequences
- Standard behaviors come for free: hiding the sidebar with ⌃⌘S, resizing columns, keyboard navigation, VoiceOver and the system's appearance.
- Opening the sidebar or inspector makes the photo smaller instead of covering part of it.
- A second window for comparing photos would need its own selection; that is not planned.
