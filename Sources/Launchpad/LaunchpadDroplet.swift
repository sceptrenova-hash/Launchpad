//
//  LaunchpadDroplet.swift
//  Launchpad
//
//  The droplet shell around the ported launcher engine: a shelf tile that
//  opens the fullscreen launchpad, and a settings pane in Droppy's Settings.
//  The launcher itself — grid, pages, search, hotkeys, gestures — is the
//  ported engine (LauncherView and its sources).
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(LaunchpadPrincipal)
public final class LaunchpadPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { LaunchpadDroplet() }
}

/// Launchpad.
@MainActor
public final class LaunchpadDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "launchpad"

    private var host: DropletHost?
    let engine = LauncherEngine()

    public func activate(host: DropletHost) throws {
        self.host = host
        launchpadExceptionDumpDirectory = host.environment.containerDirectory
        installExceptionDump()
        engine.start()
        host.log.info("Launchpad activated with \(engine.orderedItems.count) items")
    }

    public func deactivate() {
        engine.stop()
        host = nil
    }

    /// Opens (or closes) the launchpad.
    public func open() {
        engine.toggle()
    }

    /// While this droplet is installed, an uncaught Obj-C exception anywhere
    /// in the host process writes its name, reason and stack into this
    /// droplet's container before the app aborts. Purely diagnostic.
    private func installExceptionDump() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "nil")
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            if let directory = launchpadExceptionDumpDirectory {
                try? text.write(
                    to: directory.appendingPathComponent("last-exception.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }
}

private nonisolated(unsafe) var launchpadExceptionDumpDirectory: URL?

// MARK: - Shelf widget

extension LaunchpadDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "launchpad",
                title: "Launchpad",
                systemImage: "square.grid.2x2",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 210,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(LaunchpadWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// The shelf tile: a monochrome tile grid; the whole tile toggles the
/// launchpad. Hover lifts it, press settles it, and the little grid dots
/// ripple on hover — micro-animation, nothing more.
private struct LaunchpadWidget: View {
    @ObservedObject var droplet: LaunchpadDroplet
    let context: ShelfWidgetContext

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Launchpad")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            Button {
                droplet.open()
            } label: {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(spacing: DroppySpacing.xs) {
                        ForEach(0..<9, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(DroppyOpacity.visible))
                                .frame(width: 14, height: 14)
                                .scaleEffect(isHovered ? 1.12 : 1)
                                .animation(
                                    DroppyAnimation.hover.delay(Double(index) * 0.025),
                                    value: isHovered
                                )
                            if (index + 1) % 3 == 0 && index < 8 {
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Open Launchpad")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)

                    Text("⇧⌘Space or tap")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                .padding(DroppySpacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: DroppyRadius.large, style: .continuous)
                        .fill(AdaptiveColors.notchSurfacePrimaryText.opacity(isHovered ? DroppyOpacity.subtle : 0))
                }
            }
            .buttonStyle(TileButtonStyle())
            .onHover { hovered in
                withAnimation(DroppyAnimation.hover) {
                    isHovered = hovered
                }
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Settles under the pointer, springs back on release.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DroppyAnimation.hover, value: configuration.isPressed)
    }
}

// MARK: - Settings pane

extension LaunchpadDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(LaunchpadSettingsView(engine: engine))
    }
}

/// Launchpad's page in Droppy's Settings, built from the host's own rows and
/// driving the ported launcher's persistence.
struct LaunchpadSettingsView: View {
    @ObservedObject var engine: LauncherEngine

    var body: some View {
        DropletSettingsPane {
            DropletSettingsSection {
                settingsSectionHeader("Layout")
            } content: {
                DropletSettingsCard {
                    DropletGroupedPickerRow(title: "Launcher mode") {
                        Picker("", selection: modeBinding) {
                            Text("Floaty panel").tag(LauncherMode.floaty)
                            Text("Fullscreen").tag(LauncherMode.fullscreen)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    DropletGroupedPickerRow(title: "Icon size") {
                        Picker("", selection: iconSizeBinding) {
                            Text("Small").tag(IconSizePreference.small)
                            Text("Medium").tag(IconSizePreference.medium)
                            Text("Large").tag(IconSizePreference.large)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    DropletGroupedPickerRow(title: "Page direction") {
                        Picker("", selection: pagingBinding) {
                            Text("Horizontal").tag(PagingOrientation.horizontal)
                            Text("Vertical").tag(PagingOrientation.vertical)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Grid")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Collapse gaps",
                        subtitle: "Pulls items forward so pages stay full.",
                        isOn: gapsBinding
                    )
                    DropletControlRow(title: "Reset arrangement") {
                        Button("Reset") {
                            engine.resetArrangement()
                        }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Opening")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Hot corner",
                        subtitle: "Flick the cursor into the chosen corner — on any screen, in any app — to open or close the launchpad.",
                        isOn: hotCornerBinding
                    )
                    DropletGroupedPickerRow(title: "Corner") {
                        Picker("", selection: cornerBinding) {
                            Text("Bottom right").tag(HotCornerPosition.bottomRight)
                            Text("Bottom left").tag(HotCornerPosition.bottomLeft)
                            Text("Top right").tag(HotCornerPosition.topRight)
                            Text("Top left").tag(HotCornerPosition.topLeft)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    DropletControlRow(title: "Keyboard shortcut") {
                        DropletValuePill(text: "⇧⌘Space")
                    }
                }
            }
        }
    }

    private var modeBinding: Binding<LauncherMode> {
        Binding(
            get: { engine.currentSettings.selectedLauncherMode },
            set: { mode in
                LauncherSettingsPersistence.setLauncherMode(mode)
                engine.applySettingsChange()
            }
        )
    }

    private var iconSizeBinding: Binding<IconSizePreference> {
        Binding(
            get: { engine.currentSettings.iconSizePreference },
            set: { preference in
                LauncherSettingsPersistence.setIconSizePreference(preference)
                engine.applySettingsChange()
            }
        )
    }

    private var pagingBinding: Binding<PagingOrientation> {
        Binding(
            get: { engine.currentSettings.pagingOrientation },
            set: { orientation in
                LauncherSettingsPersistence.setPagingOrientation(orientation)
                engine.applySettingsChange()
            }
        )
    }

    private var hotCornerBinding: Binding<Bool> {
        Binding(
            get: { engine.currentSettings.hotCornerEnabled },
            set: { on in
                LauncherSettingsPersistence.setHotCornerEnabled(on)
                engine.applySettingsChange()
            }
        )
    }

    private var cornerBinding: Binding<HotCornerPosition> {
        Binding(
            get: { engine.currentSettings.hotCornerPosition },
            set: { corner in
                LauncherSettingsPersistence.setHotCornerPosition(corner)
                engine.applySettingsChange()
            }
        )
    }

    private var gapsBinding: Binding<Bool> {
        Binding(
            get: { engine.currentSettings.fillsGapsAutomatically },
            set: { on in
                LauncherSettingsPersistence.setFillsGapsAutomatically(on)
                engine.applySettingsChange()
            }
        )
    }
}
