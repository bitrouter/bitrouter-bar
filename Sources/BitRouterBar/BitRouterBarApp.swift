import AppKit
import SwiftUI

@main
struct BitRouterBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = PanelStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var qaWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let opensForQA = ProcessInfo.processInfo.environment["BITROUTER_BAR_QA_OPEN_ON_LAUNCH"] == "1"
        NSApp.setActivationPolicy(opensForQA ? .regular : .accessory)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.contentViewController = NSHostingController(rootView: PanelView(store: store))
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "BitRouter")
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.setAccessibilityLabel("BitRouter")
        }
        statusItem = item

        if opensForQA {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                togglePopover()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "BitRouter Bar QA"
                window.contentViewController = NSHostingController(rootView: PanelView(store: store))
                window.center()
                window.makeKeyAndOrderFront(nil)
                qaWindow = window
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        store.panelDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        store.panelDidClose()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.panelDidClose()
    }
}
