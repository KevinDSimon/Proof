import UIKit

/// On iPhone, only the editor turns to landscape, where it shows the photo alone (#321); every
/// other screen stays in portrait. The Info.plist lists the landscape orientations so the editor
/// can allow them, and this delegate narrows them to portrait everywhere else. iPad turns
/// everywhere.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Whether the iPhone may turn to landscape now.
    private static var allowsLandscape = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return Self.allowsLandscape ? .allButUpsideDown : .portrait
    }

    /// Allows or stops landscape on iPhone. Stopping it turns a phone held in landscape back to
    /// portrait.
    static func allowLandscape(_ allows: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone, allows != allowsLandscape else { return }
        allowsLandscape = allows
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if !allows {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    /// Turns the editor to the landscape orientation the phone is held in. The device's left is
    /// the interface's right.
    static func turnToLandscape(_ device: UIDeviceOrientation) {
        guard allowsLandscape, device.isLandscape else { return }
        let orientation: UIInterfaceOrientationMask = device == .landscapeLeft ? .landscapeRight : .landscapeLeft
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        }
    }
}
