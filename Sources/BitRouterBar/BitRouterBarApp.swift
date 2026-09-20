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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let store = PanelStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
#if DEBUG
    private var qaWindow: NSWindow?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        let opensForQA = ProcessInfo.processInfo.environment["BITROUTER_BAR_QA_OPEN_ON_LAUNCH"] == "1"
        NSApp.setActivationPolicy(opensForQA ? .regular : .accessory)
#else
        NSApp.setActivationPolicy(.accessory)
#endif
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

#if DEBUG
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
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: PanelView(store: store))
                window.delegate = self
                window.center()
                window.makeKeyAndOrderFront(nil)
                qaWindow = window
                saveQAScreenshotIfRequested(window)
            }
        }
#endif
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

    func windowWillClose(_ notification: Notification) {
        store.panelDidClose()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
#if DEBUG
        guard let qaWindow else { return true }
        qaWindow.makeKeyAndOrderFront(nil)
        store.panelDidOpen()
#endif
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

#if DEBUG
    private func saveQAScreenshotIfRequested(_ window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["BITROUTER_BAR_QA_SCREENSHOT_PATH"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let view = window.contentView,
                  let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            guard let png = image.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
#endif
}
