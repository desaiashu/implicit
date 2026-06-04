import SwiftUI

/// SwiftUI entry only to get a main-actor `@main` and host the AppKit delegate.
/// The menubar item + popover are all built in `AppDelegate`; the empty Settings
/// scene never shows a window (the app is a `.accessory` agent — no dock icon).
@main
struct ImplicitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
