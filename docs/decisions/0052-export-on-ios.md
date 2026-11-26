# 0052. Export on iPad and iPhone

Date: 2026-11-26
Status: Accepted. Extends 0031 and 0048.

## Context
Decision 0048 says Share on iPad and iPhone opens the export sheet with the Mac's choices, then the share sheet, Save to Files or Save to Photos, and that long batches keep running in the background. The Mac's sheet asks for a folder before the export starts and writes straight into it (decision 0031). iOS has no folder to write into until the person picks one, and the share sheet and Photos take finished files, not a folder.

iOS also takes the GPU from an app in the background: a Metal command buffer submitted there fails. Rendering keeps going only with a continued-processing background task and its GPU entitlement, which needs a new capability in the app's provisioning.

## Decision
- **One sheet, then a destination.** The sheet's format, size, color space and Remove Location are the Mac's, from the shared `ExportSettingsForm`. Above them are three destinations: Share…, Save to Files… and Save to Photos. Tapping one starts the export with those settings, which are remembered for the next export as on the Mac (`ExportSettings.remembered`). There are no saved destinations on iOS. The touch-and-hold menu's Export To lists the same three destinations and exports with the remembered settings at once.
- **Render first, then hand over.** `ExportQueue.start(_:settings:delivery:)` renders into a new temporary folder (`ExportStaging`) with the same `PhotoExport` as the Mac, so files match the Mac's for the same recipe. When every photo is ready, the share sheet or Save to Files (`fileMover`) opens on its own; a button in the sheet opens it again if it was closed without saving. Save to Photos adds each photo as soon as it is ready, moving the file into the library. Done, or swiping the finished sheet away, removes the temporary folder. Folders left by an export the app was quit during are removed when the next one starts.
- **Add-only Photos access.** The first Save to Photos asks for add-only access, with the usage description "Proof adds the photos you export to your library. It can't see the photos already there." If access is refused, each photo fails with a reason that says where to allow it.
- **Background means in-app.** As on the Mac, the export runs while the person keeps browsing and editing, and its progress stays in the sheet. When the app goes into the background, the queue waits before the next photo (`PauseGate`) and carries on when the app returns. A render that fails because the app left the foreground during it goes back to the front of the queue instead of failing.

## Consequences
- Exports keep the Mac's pipeline and metadata unchanged; only where the files go differs.
- Each export briefly takes twice its size in storage for Share and Save to Files, until the files are handed over or Done is tapped.
- A batch doesn't advance while the app is in the background. Rendering in the background with `BGContinuedProcessingTask` and its GPU entitlement is a later change, since it needs a provisioning capability.
