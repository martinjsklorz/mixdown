import AppKit
import SwiftUI

extension View {
    /// Runs `action` whenever a window of Mixdown's becomes key, such as on returning from System
    /// Settings, for views showing something the user can change there.
    func onWindowBecomesKey(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            action()
        }
    }
}
