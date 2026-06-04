import AppKit
import Combine
import SwiftUI

/// Drives the menubar item with AppKit (NSStatusItem + NSPopover) rather than
/// SwiftUI's MenuBarExtra: a real popover stays open as its own floating window,
/// so it doesn't get dismissed when the system's auto-hiding menu bar slides up
/// while you're adjusting the sliders.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = FilterController()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menubar agent, no dock icon

        popover.behavior = .transient // closes on click-outside; persists while you interact
        popover.contentViewController = NSHostingController(rootView: ControlsView(controller: controller))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()

        // Reflect on/off in the menubar glyph.
        iconObserver = controller.$isOn.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    private func updateIcon() {
        // On = "you're covered"; off = "⚠ audio is unfiltered".
        let name = controller.isOn ? "ear.badge.checkmark" : "ear.trianglebadge.exclamationmark"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Implicit")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
