import AppKit
import SwiftUI

/// The toolbar's export button: a progress ring while photos export, then a checkmark, or a
/// warning when some failed, until the summary is dismissed. Its popover says how far the export
/// has got and can stop it.
struct ExportProgressButton: View {
    let exports: ExportQueue
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails.toggle()
        } label: {
            if exports.isRunning {
                ProgressView(value: exports.fractionDone)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Label("Export", systemImage: exports.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
            }
        }
        .help(exports.isRunning ? "Exporting \(exports.finished + 1) of \(exports.total)" : "Export finished")
        .accessibilityLabel(exports.isRunning ? "Export progress" : "Export finished")
        .accessibilityValue(exports.isRunning ? "\(exports.finished) of \(exports.total) photos" : "")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            ExportDetails(exports: exports) { isShowingDetails = false }
        }
    }
}

private struct ExportDetails: View {
    let exports: ExportQueue
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if exports.isRunning {
                Text("Exporting \(min(exports.finished + 1, exports.total)) of \(exports.total)")
                    .font(.headline)
                ProgressView(value: exports.fractionDone)
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

    private var title: String {
        let count = exports.exported.count
        let photos = count == 1 ? "1 Photo" : "\(count) Photos"
        return exports.wasCancelled ? "Export Stopped: \(photos) Exported" : "Exported \(photos)"
    }
}
