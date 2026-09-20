import Foundation

/// How the loop logs cards.
///
/// Lived in `ScannerView.swift` until 2026-09-18, where it was the only thing
/// still referenced after VisionKit was dropped.
enum ScanMode: String, CaseIterable {
    /// Every card that passes through the frame logs on its own. For a stack
    /// or a card slinger.
    case automatic
    /// Nothing logs until the shutter is tapped. For a binder page, where
    /// nine cards sit in view at once.
    case manual

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .manual: return "Manual"
        }
    }
}

/// What the loop is doing when nothing is wrong.
///
/// Every one of these used to be the same thing on screen: nothing. A scanner
/// refusing a card, a scanner that has gone quiet, and a scanner pointed at an
/// empty chute were indistinguishable, so a run that had died looked exactly
/// like a run between cards.
enum ScanState: Equatable {
    /// An empty chute. Nothing is wrong.
    case idle
    /// A card is there and something is still missing.
    case reading(Missing)
    /// Detail fills the frame and no card can be found in it. He is almost
    /// always too close for the card's edges to fit.
    case tooClose
    /// This card is the one just logged.
    case alreadyLogged
    /// Readable, and refused for longer than that should take.
    case stalled
    /// Nothing logs until he taps the shutter.
    case manual

    /// One line for the status bar.
    var message: String {
        switch self {
        case .idle: return "Looking — hold a card in the box"
        case .reading(let missing): return missing.message
        case .tooClose: return "Too close — move back so the card's edges fit"
        case .alreadyLogged: return "Same card still in frame"
        case .stalled: return "Cannot read this card — tap Scan again"
        case .manual: return "Manual — tap the shutter to log a card"
        }
    }
}

/// What the loop is still waiting for on the card in front of it.
struct Missing: OptionSet, Equatable {
    let rawValue: Int
    static let number = Missing(rawValue: 1 << 0)
    static let name = Missing(rawValue: 1 << 1)

    var message: String {
        if contains(.number), contains(.name) { return "Card seen — reading it" }
        if contains(.number) { return "Card seen — reading the number" }
        return "Card seen — reading the name"
    }
}

/// Why the scanner cannot work, in words he can act on.
///
/// Every one of these was a silent `return` or an unread string before. A
/// scanner that has stopped looks exactly like a scanner pointed at an empty
/// chute, and he spent a rip believing the second while it was the first. The
/// rule this type exists to enforce: nothing in the scan path fails quietly.
enum ScannerFault: Equatable {
    /// He said no to the camera, or said yes and then turned it off.
    case permissionDenied
    /// No lens this phone offers can do the job.
    case noCamera
    /// The session would not start. Carries what AVFoundation said.
    case configurationFailed(String)
    /// No catalog is installed or open, so nothing can be looked up.
    case catalogClosed
    /// The matcher threw. Carries what it said.
    case matchFailed(String)
    /// The card was read and could not be written down. The worst of them:
    /// every other fault costs a card, this one loses a card he watched land.
    case saveFailed(String)

    /// One line, in the words he needs, not the words the error used.
    var message: String {
        switch self {
        case .permissionDenied:
            return "The camera is off for this app."
        case .noCamera:
            return "This phone has no camera the scanner can use."
        case .configurationFailed(let why):
            return "The camera would not start. \(why)"
        case .catalogClosed:
            return "The catalog is not open, so cards cannot be identified."
        case .matchFailed(let why):
            return "The card could not be looked up. \(why)"
        case .saveFailed(let why):
            return "A scanned card could not be saved. \(why)"
        }
    }

    /// The one thing that fixes it. Nil where he can only try again.
    var repair: Repair? {
        switch self {
        case .permissionDenied: return .openSettings
        case .noCamera: return nil
        case .configurationFailed: return .retryCamera
        case .catalogClosed: return .fixCatalog
        case .matchFailed: return nil
        case .saveFailed: return nil
        }
    }

    enum Repair: Equatable {
        case openSettings
        case retryCamera
        case fixCatalog

        var title: String {
            switch self {
            case .openSettings: return "Open Settings"
            case .retryCamera: return "Try again"
            case .fixCatalog: return "Fix catalog"
            }
        }
    }
}
