import AppKit
import SwiftUI

/// A small spinner beside the sidebar button while the sidebar, and the export footer with it,
/// is collapsed. Clicking it opens the sidebar. Once the export ends it goes, and the footer keeps
/// the summary.
struct ExportBadge: View {
    let exports: ExportQueue
    let showSidebar: () -> Void

    var body: some View {
        Button(action: showSidebar) {
            ProgressView()
                .controlSize(.small)
        }
        .help("Exporting \(exports.position) of \(exports.total). Click to show the sidebar.")
        .accessibilityLabel("Export progress")
        .accessibilityValue("\(exports.position) of \(exports.total) photos")
    }
}

/// The export's progress at the foot of the sidebar, where it's seen without being looked for:
/// a bar and which photo is being exported, with Stop, then how many photos were exported, with
/// Show in Finder and the failures, until it is closed. A render can't report how far it has got,
/// so for one photo the bar runs without a value; for several it counts the photos done.
struct ExportFooter: View {
    let exports: ExportQueue
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if exports.isRunning {
                    Text("Exporting \(exports.position) of \(exports.total)")
                        .monospacedDigit()
                } else {
                    Label(exports.summary, systemImage: exports.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                }
                Spacer(minLength: 0)
                Group {
                    if exports.isRunning {
                        Button("Stop Export", systemImage: "xmark.circle.fill") { exports.cancel() }
                            .help("Stop after the photo being exported")
                    } else {
                        Button("Close", systemImage: "xmark.circle.fill") { exports.clear() }
                            .help("Close")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            if exports.isRunning {
                Group {
                    if exports.total == 1 {
                        ProgressView()
                    } else {
                        ProgressView(value: exports.fractionDone)
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
                if let current = exports.current {
                    Text(current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                HStack {
                    if !exports.failures.isEmpty {
                        Button(exports.failures.count == 1 ? "1 Failed" : "\(exports.failures.count) Failed") {
                            isShowingDetails = true
                        }
                        .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
                            ExportDetails(exports: exports) { isShowingDetails = false }
                        }
                    }
                    if !exports.exported.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(exports.exported) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export")
    }
}

private struct ExportDetails: View {
    let exports: ExportQueue
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if exports.isRunning {
                Text("Exporting \(exports.position) of \(exports.total)")
                    .font(.headline)
                if exports.total == 1 {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: exports.fractionDone)
                }
                if let current = exports.current {
                    Text(current)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Stop Export") { exports.cancel() }
                }
            } else {
                Text(title)
                    .font(.headline)
                if !exports.failures.isEmpty {
                    Text(exports.failures.count == 1 ? "1 photo couldn't be exported:" : "\(exports.failures.count) photos couldn't be exported:")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(exports.failures) { failure in
                                Text("\(failure.name): \(failure.reason)")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                HStack {
                    Spacer()
                    if !exports.exported.isEmpty {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(exports.exported)
                        }
                    }
                    Button("Done") {
                        close()
                        exports.clear()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var title: String { exports.summary }
}

extension ExportQueue {
    /// How the finished export went, as the footer and the popover title it.
    var summary: String {
        let count = exported.count
        let photos = count == 1 ? "1 Photo" : "\(count) Photos"
        return wasCancelled ? "Export Stopped: \(photos) Exported" : "Exported \(photos)"
    }
}
