import AppKit
import Combine

@MainActor
final class NativeMenuController: NSObject, NSMenuDelegate {
    private let store: PanelStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let dynamicBoundary = NSMenuItem.separator()
    private let refreshItem = NSMenuItem()
    private let statusFooterItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private var clientItems: [String: NSMenuItem] = [:]
    private var sessionItems: [String: NSMenuItem] = [:]
    private var quotaItems: [String: NSMenuItem] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var isRootMenuOpen = false
    private var isStopped = false

    /// The real status-item menu. Kept internal so contract tests can inspect its
    /// native item and submenu structure without adding a second QA interface.
    var rootMenu: NSMenu { menu }

    init(store: PanelStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        configureMenu()
        observeStore()
        render()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        isRootMenuOpen = false
        store.cancelAll()
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, !isRootMenuOpen else { return }
        isRootMenuOpen = true
        store.panelDidOpen()
        render()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu, isRootMenuOpen else { return }
        isRootMenuOpen = false
        store.panelDidClose()
        render()
    }

    @objc private func refresh() { store.refreshFromMenuCommand() }
    @objc private func loadMore() { store.loadMoreFromMenuCommand() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: "BitRouter"
        )
        button.setAccessibilityLabel("BitRouter")
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(dynamicBoundary)

        refreshItem.title = "Refresh"
        refreshItem.target = self
        refreshItem.action = #selector(refresh)
        refreshItem.keyEquivalent = "r"
        refreshItem.keyEquivalentModifierMask = [.command]
        menu.addItem(refreshItem)

        statusFooterItem.isEnabled = false
        statusFooterItem.isHidden = true
        menu.addItem(statusFooterItem)
        menu.addItem(.separator())

        quitItem.title = "Quit BitRouter"
        quitItem.target = self
        quitItem.action = #selector(quit)
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.isEnabled = true
        menu.addItem(quitItem)
    }

    private func observeStore() {
        let publishers: [AnyPublisher<Void, Never>] = [
            store.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            store.$errorMessage.map { _ in () }.eraseToAnyPublisher(),
            store.$isRefreshing.map { _ in () }.eraseToAnyPublisher(),
            store.$isLoadingMore.map { _ in () }.eraseToAnyPublisher(),
            store.$isStale.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            // @Published emits before committing its new value. The main dispatch
            // queue defers rendering until after the write and continues to drain
            // while AppKit is tracking a native menu.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.render() }
            .store(in: &cancellables)
    }

    private func render() {
        let presentation = MenuPresentation(
            snapshot: store.snapshot,
            errorMessage: store.errorMessage,
            isStale: store.isStale,
            isRefreshing: store.isRefreshing,
            isLoadingMore: store.isLoadingMore
        )

        var desiredRootItems: [NSMenuItem] = []
        for client in clientsInDisplayOrder(presentation.clients) {
            let clientItem = clientItems[client.id] ?? makeClientItem(id: client.id)
            clientItems[client.id] = clientItem
            clientItem.title = "\(client.title) Today \(client.token.text)"
            clientItem.attributedTitle = trailingTitle(client.title, trailing: "Today \(client.token.text)")
            let quotaAccessibility = client.quotaRows.map(\.accessibilityText).joined(separator: ". ")
            let clientAccessibility = quotaAccessibility.isEmpty
                ? "\(client.title), today \(client.token.accessibilityText)"
                : "\(client.title), today \(client.token.accessibilityText). Quota: \(quotaAccessibility)"
            clientItem.setAccessibilityLabel(clientAccessibility)
            clientItem.toolTip = client.token.toolTip
            reconcileSessions(client.sessions, clientID: client.id, in: clientItem.submenu)
            desiredRootItems.append(clientItem)

            for quota in client.quotaRows {
                let key = "\(client.id):\(quota.id)"
                let quotaItem = quotaItems[key] ?? makeQuotaItem(id: key)
                quotaItems[key] = quotaItem
                (quotaItem.view as? QuotaIndicatorView)?.update(
                    scope: quota.scopeText,
                    value: quota.valueText,
                    fraction: quota.fraction,
                    accessibilityText: quota.accessibilityText
                )
                quotaItem.view?.alphaValue = store.isStale ? 0.55 : 1
                quotaItem.title = quota.accessibilityText
                quotaItem.toolTip = quota.toolTip
                quotaItem.setAccessibilityLabel(quota.accessibilityText)
                desiredRootItems.append(quotaItem)
            }
        }

        if presentation.clients.isEmpty {
            let empty = clientItems["__empty"] ?? makeMessageItem(id: "__empty")
            clientItems["__empty"] = empty
            if store.snapshot != nil {
                empty.title = "No activity today"
            } else if store.errorMessage != nil {
                empty.title = "Usage unavailable"
            } else {
                empty.title = "Loading today’s usage…"
            }
            empty.setAccessibilityLabel(empty.title)
            desiredRootItems.append(empty)
        }

        if presentation.canLoadMore || store.isLoadingMore {
            let more = clientItems["__more"] ?? makeLoadMoreItem()
            clientItems["__more"] = more
            more.title = store.isLoadingMore ? "Loading more sessions…" : "Load More Sessions"
            more.isEnabled = !store.isLoadingMore
            desiredRootItems.append(more)
        }

        reconcile(desiredRootItems, in: menu, before: dynamicBoundary)
        refreshItem.title = presentation.isRefreshing ? "Refreshing…" : "Refresh"
        refreshItem.isEnabled = !presentation.isRefreshing
        statusFooterItem.title = presentation.status.text
        statusFooterItem.setAccessibilityLabel(presentation.status.accessibilityText)
        statusFooterItem.isHidden = presentation.status.text.isEmpty
        statusFooterItem.attributedTitle = footerTitle(
            presentation.status.text,
            isError: presentation.status.isError
        )
        if !isRootMenuOpen { pruneCaches(for: presentation) }
    }

    private func makeClientItem(id: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier("client:\(id)")
        item.isEnabled = true
        item.submenu = NSMenu()
        item.submenu?.autoenablesItems = false
        return item
    }

    private func makeQuotaItem(id: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier("quota:\(id)")
        item.isEnabled = false
        item.view = QuotaIndicatorView(frame: NSRect(x: 0, y: 0, width: 310, height: 19))
        return item
    }

    private func makeMessageItem(id: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier(id)
        item.isEnabled = false
        return item
    }

    private func makeLoadMoreItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Load More Sessions", action: #selector(loadMore), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("load-more")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func reconcileSessions(
        _ sessions: [MenuSessionPresentation],
        clientID: String,
        in submenu: NSMenu?
    ) {
        guard let submenu else { return }
        let desired = sessions.map { session in
            let key = "\(clientID):\(session.id)"
            let item = sessionItems[key] ?? makeSessionItem(id: key)
            sessionItems[key] = item
            item.title = "\(session.title) \(session.token.text)"
            item.attributedTitle = trailingTitle(session.title, trailing: session.token.text)
            item.setAccessibilityLabel("\(session.title), \(session.token.accessibilityText)")
            item.toolTip = session.token.toolTip
            item.isEnabled = false
            return item
        }

        if desired.isEmpty {
            let key = "empty:\(submenu.hash)"
            let empty = sessionItems[key] ?? makeSessionItem(id: key)
            sessionItems[key] = empty
            empty.attributedTitle = nil
            empty.title = "No sessions today"
            empty.setAccessibilityLabel(empty.title)
            empty.isEnabled = false
            reconcile([empty], in: submenu)
        } else {
            reconcile(desired, in: submenu)
        }
    }

    private func makeSessionItem(id: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier("session:\(id)")
        item.isEnabled = false
        return item
    }

    private func pruneCaches(for presentation: MenuPresentation) {
        var liveClients = Set(presentation.clients.map(\.id))
        if presentation.clients.isEmpty { liveClients.insert("__empty") }
        if presentation.canLoadMore || store.isLoadingMore { liveClients.insert("__more") }
        clientItems = clientItems.filter { liveClients.contains($0.key) }

        let liveSessions = Set(presentation.clients.flatMap { client in
            client.sessions.map { "\(client.id):\($0.id)" }
        })
        sessionItems = sessionItems.filter { liveSessions.contains($0.key) }

        let liveQuota = Set(presentation.clients.flatMap { client in
            client.quotaRows.map { "\(client.id):\($0.id)" }
        })
        quotaItems = quotaItems.filter { liveQuota.contains($0.key) }
    }

    private func clientsInDisplayOrder(
        _ clients: [MenuClientPresentation]
    ) -> [MenuClientPresentation] {
        guard isRootMenuOpen else { return clients }
        let existingOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: menu.items.enumerated().compactMap { index, item -> (String, Int)? in
            guard let identifier = item.identifier?.rawValue, identifier.hasPrefix("client:") else { return nil }
            return (String(identifier.dropFirst("client:".count)), index)
            }
        )
        return clients.enumerated().sorted { left, right in
            let leftRank = existingOrder[left.element.id]
            let rightRank = existingOrder[right.element.id]
            switch (leftRank, rightRank) {
            case let (.some(leftRank), .some(rightRank)): return leftRank < rightRank
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left.offset < right.offset
            }
        }.map(\.element)
    }

    private func reconcile(_ desired: [NSMenuItem], in target: NSMenu, before boundary: NSMenuItem? = nil) {
        for (index, item) in desired.enumerated() {
            if target.items.indices.contains(index), target.items[index] === item { continue }
            if item.menu === target { target.removeItem(item) }
            target.insertItem(item, at: index)
        }

        let end = boundary.flatMap(target.index(of:)) ?? target.items.count
        guard end > desired.count else { return }
        for index in stride(from: end - 1, through: desired.count, by: -1) {
            target.removeItem(at: index)
        }
    }

    private func trailingTitle(_ leading: String, trailing: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 270)]
        let value = NSMutableAttributedString(
            string: "\(leading)\t\(trailing)",
            attributes: [.paragraphStyle: style]
        )
        if store.isStale {
            value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                range: NSRange(location: 0, length: value.length))
        }
        let range = (value.string as NSString).range(of: trailing, options: .backwards)
        value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        return value
    }

    private func footerTitle(_ text: String, isError: Bool) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: isError ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            ]
        )
    }
}

private final class QuotaIndicatorView: NSView {
    private let scopeLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scopeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingTail

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [scopeLabel, progress, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            scopeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 95),
            progress.widthAnchor.constraint(equalToConstant: 54),
            progress.heightAnchor.constraint(equalToConstant: 6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(scope: String?, value: String, fraction: Double?, accessibilityText: String) {
        scopeLabel.stringValue = scope ?? ""
        scopeLabel.isHidden = scope == nil
        valueLabel.stringValue = value
        progress.isHidden = fraction == nil
        progress.doubleValue = min(max(fraction ?? 0, 0), 1)
        setAccessibilityLabel(accessibilityText)
        toolTip = accessibilityText
    }
}
