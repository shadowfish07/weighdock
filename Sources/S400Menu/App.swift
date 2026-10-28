// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Combine

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    var model: AppModel!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var setupWindow: NSWindow!
    private var authorizationObservation: AnyCancellable?
    private var setupObservation: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = false
        model = AppModel(preview: preview)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scalemass", accessibilityDescription: "WeighDock")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.contentSize = NSSize(width: 400, height: 620)
        popover.contentViewController = NSHostingController(rootView: AppShellView(model: model))
        setupWindow = NSWindow(contentViewController: NSHostingController(rootView: AppShellView(model: model)))
        setupWindow.title = "WeighDock"
        setupWindow.styleMask = [.titled, .closable]
        setupWindow.isReleasedWhenClosed = false
        setupWindow.delegate = self
        setupWindow.setContentSize(NSSize(width: 420, height: 650))
        authorizationObservation = model.$authorizing.sink { [weak self] active in
            // The external browser is expected to take focus during OAuth. Keep
            // its originating panel alive until completion or an explicit close.
            self?.popover.behavior = active ? .applicationDefined : .semitransient
        }
        setupObservation = model.$setupStep.dropFirst().sink { [weak self] step in
            guard step != nil, let self else { return }
            self.popover.performClose(nil)
            if !self.setupWindow.isVisible { self.showWindow() }
        }
        if model.setupStep != nil || preview { showWindow() }
    }
    @objc private func togglePanel() {
        if setupWindow.isVisible { NSApp.activate(ignoringOtherApps: true); setupWindow.makeKeyAndOrderFront(nil); return }
        if model.setupStep != nil { showWindow(); return }
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    private func showWindow() { setupWindow.center(); NSApp.activate(ignoringOtherApps: true); setupWindow.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { if model.authorizing { model.cancelOAuth() } }
    func popoverWillClose(_ notification: Notification) { if model.authorizing { model.cancelOAuth() } }
    func applicationWillTerminate(_ notification: Notification) { model.cleanupPreview() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct S400Main {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
