import SwiftUI

struct PanelView: View {
    @ObservedObject var store: PanelStore
    @State private var expandedClients = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380, height: 480)
        .background(.background)
    }

    private var header: some View {
        HStack {
            Text("BitRouter")
                .font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
        }
        .padding(14)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = store.snapshot {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.isStale, let error = store.errorMessage {
                        StatusNotice(title: "Showing older data", detail: error)
                    }
                    if snapshot.clients.isEmpty {
                        ContentUnavailableView("No activity today", systemImage: "clock")
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        ForEach(snapshot.clients.sorted(by: clientOrder)) { client in
                            clientSection(client)
                        }
                    }
                    if snapshot.sessionPage?.hasMore == true {
                        Button {
                            store.loadMore()
                        } label: {
                            if store.isLoadingMore { ProgressView() } else { Text("Load more sessions") }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(store.isLoadingMore)
                    }
                }
                .padding(14)
            }
        } else if let error = store.errorMessage {
            ContentUnavailableView("Unable to load BitRouter", systemImage: "exclamationmark.triangle", description: Text(error))
                .padding()
        } else {
            ProgressView("Loading today’s usage…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clientSection(_ client: ClientUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if expandedClients.contains(client.id) {
                    expandedClients.remove(client.id)
                } else {
                    expandedClients.insert(client.id)
                }
            } label: {
                HStack {
                    Image(systemName: expandedClients.contains(client.id) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text(client.label).fontWeight(.semibold)
                    Spacer()
                    Text("Today \(tokenText(client.tokens))")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(client.label), today \(tokenText(client.tokens))")
            .accessibilityValue(expandedClients.contains(client.id) ? "Expanded" : "Collapsed")

            ForEach(Array(client.accounts.enumerated()), id: \.offset) { _, account in
                accountRows(account)
            }

            if expandedClients.contains(client.id) {
                ForEach(client.sessions.sorted(by: sessionOrder)) { session in
                    HStack {
                        Text("Session \(session.shortID)")
                        Spacer()
                        Text(tokenText(session.tokens)).monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.leading, 18)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private func accountRows(_ account: AccountQuota) -> some View {
        let accountName = accountName(account)
        let prefix = account.shared ? "\(accountName) · Shared quota" : accountName
        switch account.quota.state {
        case .unsupported:
            quotaLine(prefix, "Quota lookup is not supported")
        case .unknown:
            quotaLine(prefix, account.mappingState == .known ? "Checking quota…" : "Quota unavailable")
        case .error:
            quotaLine(prefix, "Refresh failed\(sampleAge(account.quota.sampledAt))")
        case .stale, .available:
            if account.quota.windows.isEmpty {
                quotaLine(prefix, account.quota.state == .stale ? "Quota is stale" : "Quota unavailable")
            } else {
                ForEach(Array(account.quota.windows.enumerated()), id: \.offset) { _, window in
                    quotaLine(prefix, windowText(window, stale: account.quota.state == .stale))
                }
            }
        }
    }

    private func quotaLine(_ prefix: String, _ detail: String) -> some View {
        Text("\(prefix): \(detail)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
            .accessibilityLabel("\(prefix), \(detail)")
    }

    private func accountName(_ account: AccountQuota) -> String {
        if account.mappingState == .unknown {
            return account.label.map { "\($0) · Account unknown" } ?? "Unknown account"
        }
        return account.label ?? "Account"
    }

    private var footer: some View {
        HStack {
            if let updated = store.snapshot?.generatedAt {
                Text("Updated ") + Text(updated, style: .relative)
            } else {
                Text("Not updated")
            }
            Spacer()
            Button("Refresh") { store.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isRefreshing)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.caption)
        .padding(12)
    }

    private func tokenText(_ count: TokenCount) -> String {
        guard let value = count.value else { return "Unknown" }
        let formatted = value.formatted(.number.notation(.compactName))
        if count.state == .estimated { return "≈\(formatted)" }
        if count.hasUnknown { return "\(formatted)+ · Some usage unknown" }
        return formatted
    }

    private func windowText(_ window: QuotaWindow, stale: Bool) -> String {
        var value: String
        if let percent = window.remainingPercent {
            value = "\(percent.formatted(.number.precision(.fractionLength(0))))% remaining"
        } else if let tokens = window.remainingTokens {
            value = "\(tokens.formatted(.number.notation(.compactName))) tokens remaining"
        } else if let requests = window.remainingRequests {
            value = "\(requests.formatted()) requests remaining"
        } else if let amount = window.remainingCurrency, let currency = window.currency {
            value = "\(amount.formatted(.currency(code: currency))) remaining"
        } else {
            value = "Remaining quota unknown"
        }
        if let reset = window.resetsAt, window.resetKind != .rolling {
            value += " · resets " + reset.formatted(.relative(presentation: .numeric))
        }
        if stale { value += " · stale" }
        return "\(window.label): \(value)"
    }

    private func sampleAge(_ date: Date?) -> String {
        guard let date else { return "" }
        return " · last value \(date.formatted(.relative(presentation: .numeric)))"
    }

    private func clientOrder(_ left: ClientUsage, _ right: ClientUsage) -> Bool {
        (left.tokens.value ?? 0) > (right.tokens.value ?? 0)
    }

    private func sessionOrder(_ left: SessionUsage, _ right: SessionUsage) -> Bool {
        (left.lastActivityAt ?? .distantPast) > (right.lastActivityAt ?? .distantPast)
    }
}

private struct StatusNotice: View {
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
    }
}
