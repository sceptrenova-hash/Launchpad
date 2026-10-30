//
//  Bridge.swift
//  Launchpad
//
//  The seam between the ported launcher engine and its host. In the original
//  app these four hooks lived on the app delegate; inside the droplet they
//  are provided by the launcher engine through this bridge.
//

import AppKit

/// The host hooks the launcher view reaches for. Implemented by
/// ``LauncherEngine``.
@MainActor
protocol LaunchpadLauncherDelegate: AnyObject {
    func fadeOutLauncherWindow(restoreFocus: Bool, completion: @escaping @MainActor @Sendable () -> Void)
    func recordLaunchedApplication(_ app: AppItem, application: NSRunningApplication?)
    func focusPreferredApplicationAfterLauncherHides()
    func shrinkIconCachesForHiddenLauncher()
}

/// The live delegate, set by the engine at activation.
@MainActor
enum LauncherBridge {
    nonisolated(unsafe) static weak var delegate: LaunchpadLauncherDelegate?
}

// The view casts `NSApp?.delegate as? LaunchyAppDelegate`; inside the droplet
// the same hook is the bridge.
nonisolated(unsafe) weak var launchpadAppDelegate: LaunchpadLauncherDelegate? = nil

extension NSWindow {
    /// Applies rounded clipping to backing views for translucent windows.
    func applyRoundedCorners(radius: CGFloat) {
        guard let contentView else { return }
        let targetView = contentView.superview ?? contentView
        targetView.wantsLayer = true
        targetView.layer?.backgroundColor = NSColor.clear.cgColor
        targetView.layer?.cornerRadius = radius
        targetView.layer?.cornerCurve = .continuous
        targetView.layer?.masksToBounds = true
    }
}
