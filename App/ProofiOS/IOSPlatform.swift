import ProofUI
import SwiftUI
import UIKit

extension LibraryPlatform {
    /// The library's system calls on iPad and iPhone, through UIKit.
    static let iOS = LibraryPlatform(
        // Touch has no modifier keys. A hardware keyboard's can follow with the iPad's selection.
        clickModifiers: { [] },
        beep: { UINotificationFeedbackGenerator().notificationOccurred(.error) },
        // Show in Finder is Mac-only; iOS has no way to select files in the Files app.
        revealFiles: { _ in },
        openFolder: { url in
            guard let filesURL = URL(string: "shareddocuments://" + url.path(percentEncoded: true)) else { return }
            UIApplication.shared.open(filesURL)
        },
        copyString: { UIPasteboard.general.string = $0 },
        // iOS has no mount notifications. Drives that come and go are found when folders are
        // read again on becoming active.
        observe: { handler in
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(.becameActive) }
            }
            NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(.willTerminate) }
            }
        },
        sidewaysDrag: { view, actions in AnyView(view.gesture(SidewaysDrag(actions: actions))) },
        reducesMotion: { UIAccessibility.isReduceMotionEnabled }
    )
}
