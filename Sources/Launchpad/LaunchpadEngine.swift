//
//  LaunchpadEngine.swift
//  Launchpad
//
//  The heart of the droplet: the ported launcher engine. Owns discovery,
//  arrangement, settings, the launcher window, hotkeys, the hot corner and
//  the directory monitor — the parts the original app spread across its app
//  delegate, adapted to run inside the droplet.
//

import AppKit
import SwiftUI

@MainActor
final class LauncherEngine: ObservableObject {
    let discovery = AppDiscoveryService()
    let arrangementStore = ItemArrangementStore()

    private var windowController: LauncherWindowController?
    private var launcherHotkeyManager: HotkeyManager?
    private var layoutHotkeyManager: HotkeyManager?
    private var directoryMonitor: ApplicationDirectoryMonitor?
    private var hotCornerMonitor: HotCornerMonitor?

    private(set) var orderedItems: [LauncherItem] = []
    private(set) var pageSizes: [Int] = []
    private(set) var currentSettings: LauncherSettings = .defaults

    private var lastFocusedApplication: NSRunningApplication?
    private var launchingAppBundleID: String?

    var isLauncherVisible: Bool {
        windowController?.window?.isVisible ?? false
    }

    // MARK: Lifecycle

    func start() {
        LauncherSettingsPersistence.registerDefaults()
        currentSettings = LauncherSettingsPersistence.loadSettings()

        // The old launchpad was fullscreen, and fullscreen is what makes the
        // whole screen ours while it is up. Only honor a persisted choice
        // once the user has made one.
        if UserDefaults.standard.object(forKey: "Launchpad.launcherModeConfigured") == nil {
            if currentSettings.selectedLauncherMode != .fullscreen {
                LauncherSettingsPersistence.setLauncherMode(.fullscreen)
                currentSettings.selectedLauncherMode = .fullscreen
            }
            UserDefaults.standard.set(true, forKey: "Launchpad.launcherModeConfigured")
        }

        reloadApps()
        rebuildWindow()
        installHotkeys()
        installDirectoryMonitor()

        // The hot corner: flick the cursor into the configured corner — on
        // any screen, in any app, over any Space — to open or close.
        hotCornerMonitor = HotCornerMonitor(trigger: { [weak self] in self?.toggle() })
        applyHotCorner()

        LauncherBridge.delegate = self
        launchpadAppDelegate = self
    }

    func stop() {
        hotCornerMonitor?.stopMonitoring()
        launcherHotkeyManager?.deactivate()
        layoutHotkeyManager?.deactivate()
        directoryMonitor?.stop()
        windowController?.window?.orderOut(nil)
        windowController = nil
        LauncherBridge.delegate = nil
        launchpadAppDelegate = nil
    }

    // MARK: Public controls

    func toggle() {
        isLauncherVisible ? hide() : show()
    }

    func show() {
        recordFrontmostApplicationForRestoration()
        if windowController == nil {
            rebuildWindow()
        }
        guard let controller = windowController else { return }

        // Becoming the active app is what makes the launchpad own the screen:
        // the menu bar, key handling and every click belong to it while up.
        NSApp.activate(ignoringOtherApps: true)

        if let window = controller.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .launcherDidShow, object: nil)
        }
    }

    func hide() {
        fadeOutLauncherWindow(restoreFocus: true) { }
    }

    // MARK: Arrangement

    func reloadApps() {
        let capacity = gridConfiguration().pageCapacity
        let result = discovery.reloadApps(
            includeUserApplicationsFolder: currentSettings.shouldScanUserApplicationsFolder,
            hiddenBundleIDs: Set(currentSettings.hiddenBundleIDs),
            sorting: .alphabetical
        )
        let (items, sizes) = arrangementStore.arrangedItems(
            from: result.allVisible,
            pageCapacity: capacity,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically
        )
        orderedItems = items
        pageSizes = sizes
        windowController?.update(rootView: buildLauncherView())
    }

    /// Re-reads persisted settings and rebuilds the window for the mode.
    func applySettingsChange() {
        currentSettings = LauncherSettingsPersistence.loadSettings()
        rebuildWindow()
        applyHotCorner()
    }

    /// Re-applies the hot-corner configuration after a settings change.
    func applyHotCorner() {
        hotCornerMonitor?.update(
            enabled: currentSettings.hotCornerEnabled,
            corner: currentSettings.hotCornerPosition
        )
    }

    /// Cycles floaty ↔ fullscreen and persists the choice.
    func cycleLauncherMode() {
        let next: LauncherMode = currentSettings.selectedLauncherMode == .floaty ? .fullscreen : .floaty
        LauncherSettingsPersistence.setLauncherMode(next)
        currentSettings = LauncherSettingsPersistence.loadSettings()
        rebuildWindow()
    }

    /// Drops the persisted arrangement: pages rebuild alphabetically.
    func resetArrangement() {
        let capacity = gridConfiguration().pageCapacity
        let result = discovery.reloadApps(
            includeUserApplicationsFolder: currentSettings.shouldScanUserApplicationsFolder,
            hiddenBundleIDs: Set(currentSettings.hiddenBundleIDs),
            sorting: .alphabetical
        )
        let sizes = [Int](repeating: capacity, count: max(1, (result.allVisible.count + capacity - 1) / capacity))
        orderedItems = result.allVisible.sorted {
            $0.sortingName.localizedCaseInsensitiveCompare($1.sortingName) == .orderedAscending
        }.map { .app($0) }
        pageSizes = sizes
        arrangementStore.saveOrderedItems(orderedItems, pageSizes: sizes, pageCapacity: capacity)
        windowController?.update(rootView: buildLauncherView())
    }

    private func rebuildWindow() {
        windowController?.window?.orderOut(nil)
        windowController = LauncherWindowController(
            rootView: buildLauncherView(),
            launcherMode: currentSettings.selectedLauncherMode
        )
    }

    private func installHotkeys() {
        launcherHotkeyManager = HotkeyManager(
            descriptor: currentSettings.launcherHotkey ?? .toggleLauncher
        )
        launcherHotkeyManager?.onHotkeyPressed = { [weak self] in self?.toggle() }
        launcherHotkeyManager?.activate()

        if let layoutDescriptor = currentSettings.layoutToggleHotkey {
            layoutHotkeyManager = HotkeyManager(descriptor: layoutDescriptor)
            layoutHotkeyManager?.onHotkeyPressed = { [weak self] in self?.cycleLauncherMode() }
            layoutHotkeyManager?.activate()
        }
    }

    private func installDirectoryMonitor() {
        var directories = ["/Applications", "/System/Applications"]
        if currentSettings.shouldScanUserApplicationsFolder {
            directories.append(NSString("~/Applications").expandingTildeInPath)
        }
        directoryMonitor = ApplicationDirectoryMonitor(
            directories: directories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.reloadApps()
            }
        }
    }

    private func gridConfiguration(for mode: LauncherMode? = nil) -> LauncherGridConfiguration {
        let resolvedMode = mode ?? currentSettings.selectedLauncherMode
        let preference = currentSettings.iconSizePreference.effectivePreference(for: resolvedMode)
        return LauncherGridConfiguration.configuration(for: preference, mode: resolvedMode)
    }

    private func buildLauncherView() -> LauncherView {
        let config = gridConfiguration()
        return LauncherView(
            itemCatalog: orderedItems,
            initialPageSizes: pageSizes,
            backgroundStylePreference: currentSettings.backgroundStylePreference,
            solidBackgroundColor: currentSettings.solidBackgroundColor,
            launcherMode: currentSettings.selectedLauncherMode,
            gridConfiguration: config,
            pagingOrientation: currentSettings.pagingOrientation,
            pageRevertMode: currentSettings.pageRevertMode,
            standardPageIndex: currentSettings.standardPageIndex,
            fillsGapsAutomatically: currentSettings.fillsGapsAutomatically,
            onToggleLauncherModeRequested: { [weak self] in
                self?.cycleLauncherMode()
            },
            onItemOrderChange: { [weak self] reorderedItems, newPageSizes in
                guard let self else { return }
                self.orderedItems = reorderedItems
                self.pageSizes = newPageSizes
                self.arrangementStore.saveOrderedItems(
                    reorderedItems,
                    pageSizes: newPageSizes,
                    pageCapacity: config.pageCapacity
                )
            },
            onVisiblePagesChanged: { [weak self] apps in
                self?.prewarm(apps)
            },
            onPageSwitchPrewarm: { [weak self] apps in
                self?.prewarm(apps)
            },
            onSearchResultsFirstPage: { [weak self] apps in
                self?.prewarm(apps)
            },
            iconProvider: { [weak self] app, dimension, quality, scale in
                guard let self else { return nil }
                return self.discovery.preparedIcon(
                    for: app,
                    targetDimension: dimension,
                    quality: quality,
                    screenScale: scale
                )
            }
        )
    }

    private func prewarm(_ apps: [AppItem]) {
        discovery.preheatIcons(
            for: apps,
            targetDimension: 140,
            qualities: [.low, .medium]
        )
    }

    private func recordFrontmostApplicationForRestoration() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.isTerminated == false
        else { return }
        if let bundleID = Bundle.main.bundleIdentifier,
           frontmost.bundleIdentifier == bundleID {
            return
        }
        lastFocusedApplication = frontmost
    }
}

// MARK: - The hooks the launcher view calls into

extension LauncherEngine: LaunchpadLauncherDelegate {
    func fadeOutLauncherWindow(restoreFocus: Bool, completion: @escaping @MainActor @Sendable () -> Void) {
        guard let controller = windowController, let window = controller.window else {
            completion()
            return
        }
        controller.fadeOutWindow { [weak self] in
            NotificationCenter.default.post(name: .launcherDidHide, object: nil)
            if restoreFocus {
                self?.focusPreferredApplicationAfterLauncherHides()
            }
            completion()
        }
    }

    func recordLaunchedApplication(_ app: AppItem, application: NSRunningApplication?) {
        launchingAppBundleID = app.bundleIdentifier
        if let application {
            lastFocusedApplication = application
        }
    }

    func focusPreferredApplicationAfterLauncherHides() {
        let dropletBundleID = Bundle.main.bundleIdentifier
        if let app = lastFocusedApplication, app.isTerminated == false,
           app.bundleIdentifier != dropletBundleID {
            app.activate(options: [])
        }
        lastFocusedApplication = nil
        launchingAppBundleID = nil
    }

    func shrinkIconCachesForHiddenLauncher() {
        discovery.shrinkCachesForHiddenLauncher()
    }
}
