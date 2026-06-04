import AppKit
import Combine
import SwiftUI

/// Drives the menubar item with an NSMenu whose single item hosts the SwiftUI
/// controls. Using a real menu (not a popover) means menu tracking keeps the
/// system's auto-hiding menu bar pinned open while you adjust the sliders —
/// the behavior you get from menus like Dropbox's. A popover floats on its own
/// and lets the menu bar slide away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = FilterController()
    private var statusItem: NSStatusItem!
    private var hostingView: NSHostingView<ControlsView>!
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menubar agent, no dock icon

        hostingView = NSHostingView(rootView: ControlsView(controller: controller))
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)

        let item = NSMenuItem()
        item.view = hostingView
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu // setting .menu makes a click open it (menu-bar stays pinned)
        updateIcon()

        // Reflect on/off in the menubar glyph.
        iconObserver = controller.$isOn.sink { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    /// Re-fit the hosting view each time the menu opens (its height changes when
    /// the permission hint appears/disappears).
    func menuWillOpen(_ menu: NSMenu) {
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
    }

    private func updateIcon() {
        // On = "you're covered"; off = "⚠ audio is unfiltered".
        let name = controller.isOn ? "ear.badge.checkmark" : "ear.trianglebadge.exclamationmark"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Implicit")
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}
