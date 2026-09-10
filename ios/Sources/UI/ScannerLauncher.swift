import Foundation
import Observation

/// The one way to open the scanner from anywhere in the stack.
///
/// `RootView` owns the cover, because a pushed screen that owns a full-screen
/// cover loses it the moment the screen pops. A pushed screen sets `session`
/// and the root presents it.
@MainActor
@Observable
final class ScannerLauncher {
    var session: ScanSession?
}
