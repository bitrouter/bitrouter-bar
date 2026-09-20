import AppKit
import Foundation

@MainActor
func runNativeMenuTests(panel: PanelSnapshot, nextPage: PanelSnapshot) async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let store = PanelStore(client: PagingClient(first: panel, second: nextPage), pollingInterval: .seconds(3_600))
    let controller = NativeMenuController(store: store)
    defer { controller.stop() }
    let menu = controller.rootMenu

    controller.menuWillOpen(menu)
    try await waitFor({ menu.items.contains { $0.identifier?.rawValue == "client:opaque-client" } }, "native menu renders completed asynchronous snapshot")
    guard let client = menu.items.first(where: { $0.identifier?.rawValue == "client:opaque-client" }),
          let submenu = client.submenu else {
        throw ContractTestFailure.assertion("client uses native session submenu")
    }
    try expect(client.view == nil && client.isEnabled, "client remains a native keyboard-reachable row")
    try expect(client.title.contains("Codex"), "client native title supports type-select")
    try expect(client.attributedTitle?.string.contains("Today") == true, "today scope is visible")
    try expect(submenu.items.first?.view == nil, "session rows use native menu rendering")
    let quotaRows = menu.items.filter { $0.identifier?.rawValue.hasPrefix("quota:") == true }
    try expect(quotaRows.count == 1, "one compact quota row for one window")
    try expect(quotaRows.allSatisfy { ($0.view?.frame.height ?? 0) > 0 && ($0.view?.frame.height ?? 0) < 32 }, "quota menu view has a real compact frame before attachment")
    try expect(quotaRows.allSatisfy { !$0.title.isEmpty && !$0.isEnabled }, "read-only quota exposes text without fake menu action")
    guard let refreshIndex = menu.items.firstIndex(where: { $0.keyEquivalent == "r" }),
          let quit = menu.items.first(where: { $0.keyEquivalent == "q" }) else {
        throw ContractTestFailure.assertion("native refresh and quit shortcuts")
    }
    try expect(quit.title == "Quit BitRouter" && quit.view == nil, "native quit command")
    try expect(menu.items[refreshIndex].keyEquivalentModifierMask == [.command], "refresh uses Command-R")

    // Closing a submenu is not closing the root menu.
    controller.menuDidClose(submenu)
    store.refresh()
    try expect(store.isRefreshing, "submenu dismissal does not close the store")
    try await waitFor({ !store.isRefreshing }, "refresh completes while root remains open")
    try await Task.sleep(for: .milliseconds(20))
    try expect(menu.items.contains { $0 === client } && client.submenu === submenu, "refresh retains native parent/submenu identity")

    controller.menuDidClose(menu)
    menu.performActionForItem(at: refreshIndex)
    try expect(store.isRefreshing, "native Refresh action starts after menu dismissal")
    try await waitFor({ !store.isRefreshing }, "native Refresh action completes after dismissal")
    guard let moreIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "load-more" }) else {
        throw ContractTestFailure.assertion("pagination remains reachable")
    }
    menu.performActionForItem(at: moreIndex)
    try await waitFor({ !store.isLoadingMore && store.snapshot?.clients.first?.sessions.count == 2 }, "native Load More finishes into cache")
    controller.menuWillOpen(menu)
    try await waitFor({ submenu.items.count == 2 }, "reopening exposes appended native session rows")
    controller.menuDidClose(menu)
}
