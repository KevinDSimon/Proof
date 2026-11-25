import AppKit
import SwiftUI
import ProofUI

/// The export sheet once Export is clicked, and for File › Export To: which photo is being
/// exported, a bar and Stop, then how many photos were exported, which failed and why, and Show in
/// Finder. It stays open until the export ends and Done is clicked, so an export is never missed
/// (#196). A render can't report how far it has got, so for one photo the bar runs without a
/// value; for several it counts the photos done.
struct ExportProgressView: View {
    let exports: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if exports.isRunning {
                Text(exports.total == 1 ? "Exporting 1 Photo" : "Exporting \(exports.position) of \(exports.total)")
                    .font(.headline)
                    .monospacedDigit()
                Group {
                    if exports.total == 1 {
                        ProgressView()
                    } else {
                        ProgressView(value: exports.fractionDone)
                    }
                }
                .progressViewStyle(.linear)
                // A render can't be stopped once it starts, so Stop takes effect after this photo.
                Text(exports.wasCancelled ? "Stopping after this photo…" : exports.current ?? " ")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Spacer()
                    Button("Stop Export") { exports.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(exports.wasCancelled)
                }
            } else {
                Label(exports.summary, systemImage: exports.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
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
                    Button("Done") { exports.clear() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled(exports.isRunning)
    }
}

extension ExportQueue {
    /// How the finished export went, as the sheet titles it.
    var summary: String {
        let count = exported.count
        let photos = count == 1 ? "1 Photo" : "\(count) Photos"
        return wasCancelled ? "Export Stopped: \(photos) Exported" : "Exported \(photos)"
    }
}
