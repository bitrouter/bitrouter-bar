import Foundation

struct MenuTokenPresentation: Equatable, Sendable {
    let text: String
    let accessibilityText: String
    let toolTip: String
}

struct MenuQuotaRowPresentation: Equatable, Sendable {
    let id: String
    let scopeText: String?
    let valueText: String
    let accessibilityText: String
    let toolTip: String
    let fraction: Double?
}

struct MenuSessionPresentation: Equatable, Sendable {
    let id: String
    let title: String
    let token: MenuTokenPresentation

    var tokenText: String { token.text }
}

struct MenuClientPresentation: Equatable, Sendable {
    let id: String
    let title: String
    let token: MenuTokenPresentation
    let sessions: [MenuSessionPresentation]
    let quotaRows: [MenuQuotaRowPresentation]

    var tokenText: String { token.text }
}

struct MenuStatusPresentation: Equatable, Sendable {
    let text: String
    let accessibilityText: String
    let isError: Bool
}

struct MenuPresentation: Equatable, Sendable {
    let clients: [MenuClientPresentation]
    let status: MenuStatusPresentation
    let isRefreshing: Bool
    let canLoadMore: Bool

    var statusText: String { status.text }

    init(
        snapshot: PanelSnapshot?,
        errorMessage: String?,
        isStale: Bool,
        isRefreshing: Bool,
        isLoadingMore: Bool,
        now: Date = Date()
    ) {
        clients = snapshot?.clients
            .sorted { ($0.tokens.value ?? 0) > ($1.tokens.value ?? 0) }
            .map { Self.client($0, now: now) } ?? []
        status = Self.status(snapshot: snapshot, errorMessage: errorMessage, isStale: isStale, isRefreshing: isRefreshing, now: now)
        self.isRefreshing = isRefreshing
        canLoadMore = snapshot?.sessionPage?.hasMore == true && !isLoadingMore
    }

    static func token(_ count: TokenCount) -> MenuTokenPresentation {
        guard let value = count.value else {
            let unknown = count.state == .estimated ? "Estimated token count unknown" : "Token count unknown"
            return MenuTokenPresentation(text: "Unknown", accessibilityText: unknown, toolTip: unknown)
        }

        let compact = compactNumber(value)
        let exact = value.formatted(.number.locale(Locale(identifier: "en_US")))
        let estimatePrefix = count.state == .estimated ? "≈" : ""
        let unknownSuffix = count.hasUnknown ? "+" : ""
        var qualifiers: [String] = []
        if count.state == .estimated { qualifiers.append("estimated") }
        if count.hasUnknown { qualifiers.append("some usage unknown") }
        let detail = qualifiers.isEmpty ? "\(exact) tokens" : "\(exact) tokens; " + qualifiers.joined(separator: "; ")
        return MenuTokenPresentation(
            text: "\(estimatePrefix)\(compact)\(unknownSuffix)",
            accessibilityText: detail,
            toolTip: detail
        )
    }

    private static func client(_ client: ClientUsage, now: Date) -> MenuClientPresentation {
        let sessions = client.sessions
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .map {
                let title = $0.shortID.contains("未知") ? "Unknown session" : "Session \($0.shortID)"
                return MenuSessionPresentation(id: $0.id, title: title, token: token($0.tokens))
            }
        let quotaRows = client.accounts.enumerated().flatMap { accountIndex, account in
            Self.quotaRows(account, accountIndex: accountIndex, accountCount: client.accounts.count, now: now)
        }
        return MenuClientPresentation(
            id: client.id,
            title: englishClientLabel(client.label),
            token: token(client.tokens),
            sessions: sessions,
            quotaRows: quotaRows
        )
    }

    private static func quotaRows(
        _ account: AccountQuota,
        accountIndex: Int,
        accountCount: Int,
        now: Date
    ) -> [MenuQuotaRowPresentation] {
        let accountScope = accountScope(account, index: accountIndex, count: accountCount)
        let prefix = account.id ?? "unknown-\(accountIndex)"
        switch account.quota.state {
        case .unsupported:
            return [quotaStateRow(id: prefix, scope: accountScope, text: "Quota unsupported")]
        case .unknown:
            let text = account.mappingState == .unknown ? "Quota unavailable" : "Checking quota…"
            return [quotaStateRow(id: prefix, scope: accountScope, text: text)]
        case .error:
            let text = "Refresh failed · \(sampleDescription(account.quota.sampledAt, now: now))"
            return [quotaStateRow(id: prefix, scope: accountScope, text: text)]
        case .available, .stale:
            guard !account.quota.windows.isEmpty else {
                let text = account.quota.state == .stale
                    ? "Quota stale · \(sampleDescription(account.quota.sampledAt, now: now))"
                    : "Quota unavailable"
                return [quotaStateRow(id: prefix, scope: accountScope, text: text)]
            }
            return account.quota.windows.enumerated().map { windowIndex, window in
                quotaWindowRow(
                    window,
                    id: "\(prefix)-\(windowIndex)-\(simplifiedWindowLabel(window.label))",
                    accountScope: accountScope,
                    stale: account.quota.state == .stale,
                    sampledAt: account.quota.sampledAt,
                    now: now
                )
            }
        }
    }

    private static func quotaWindowRow(
        _ window: QuotaWindow,
        id: String,
        accountScope: String?,
        stale: Bool,
        sampledAt: Date?,
        now: Date
    ) -> MenuQuotaRowPresentation {
        let scope = [accountScope, simplifiedWindowLabel(window.label)].compactMap { $0 }.joined(separator: " · ")
        let value: String
        let fraction: Double?
        if let percent = window.remainingPercent {
            value = "\(percent.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))))% left"
            fraction = (0 ... 100).contains(percent) ? percent / 100 : nil
        } else if let tokens = window.remainingTokens {
            value = "\(compactNumber(tokens)) tokens left"
            fraction = nil
        } else if let requests = window.remainingRequests {
            value = "\(requests.formatted(.number.locale(Locale(identifier: "en_US")))) requests left"
            fraction = nil
        } else if let amount = window.remainingCurrency, let currency = window.currency {
            value = amount.formatted(.currency(code: currency).locale(Locale(identifier: "en_US"))) + " left"
            fraction = nil
        } else {
            value = "Remaining unknown"
            fraction = nil
        }

        var details: [String] = [value]
        if let reset = window.resetsAt {
            switch window.resetKind {
            case .fixed:
                details.append("resets \(relativeTime(reset, now: now))")
            case .unknown, nil:
                details.append("upstream reset \(relativeTime(reset, now: now))")
            case .rolling:
                break
            }
        } else if window.resetKind == .fixed {
            details.append("reset time unknown")
        }
        let visibleValue = stale ? "\(value) · stale (\(compactAge(sampledAt, now: now)))" : value
        if stale { details.append("stale, \(sampleDescription(sampledAt, now: now))") }
        let accessibility = scope.isEmpty ? details.joined(separator: ", ") : "\(scope), " + details.joined(separator: ", ")
        return MenuQuotaRowPresentation(
            id: id,
            scopeText: scope.isEmpty ? nil : scope,
            valueText: visibleValue,
            accessibilityText: accessibility,
            toolTip: accessibility,
            fraction: fraction
        )
    }

    private static func quotaStateRow(id: String, scope: String?, text: String) -> MenuQuotaRowPresentation {
        MenuQuotaRowPresentation(
            id: id,
            scopeText: scope,
            valueText: text,
            accessibilityText: [scope, text].compactMap { $0 }.joined(separator: ", "),
            toolTip: [scope, text].compactMap { $0 }.joined(separator: ", "),
            fraction: nil
        )
    }

    private static func accountScope(_ account: AccountQuota, index: Int, count: Int) -> String? {
        if account.mappingState == .unknown {
            guard let label = account.label, !label.contains("未知") else { return "Unknown account" }
            return "\(simplifiedAccountLabel(label, fallbackIndex: index)) · Unknown account"
        }
        if account.shared {
            if count == 1 { return "Shared quota" }
            let label = account.label.map { simplifiedAccountLabel($0, fallbackIndex: index) } ?? "Account \(index + 1)"
            return "\(label) · Shared quota"
        }
        guard count > 1 else { return nil }
        return account.label.map { simplifiedAccountLabel($0, fallbackIndex: index) } ?? "Account \(index + 1)"
    }

    private static func simplifiedAccountLabel(_ label: String, fallbackIndex: Int) -> String {
        let translated = label.replacingOccurrences(of: "账户", with: "Account ")
        let words = translated.split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "-" })
        let kept = words.filter { word in
            let normalized = word.lowercased()
            return normalized != "codex" && normalized != "primary"
        }
        let result = kept.joined(separator: " ")
        guard !result.isEmpty else { return "Account \(fallbackIndex + 1)" }
        return result.replacingOccurrences(of: "account", with: "Account", options: [.caseInsensitive, .anchored])
    }

    private static func simplifiedWindowLabel(_ label: String) -> String {
        let components = label.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let meaningful = components.compactMap { component -> String? in
            switch component.lowercased() {
            case "codex", "primary": return nil
            case "5-hour", "5 hour", "five-hour": return "5h quota"
            case "weekly", "week": return "Weekly quota"
            default: return component
            }
        }
        return meaningful.joined(separator: " · ")
    }

    private static func englishClientLabel(_ label: String) -> String {
        label.contains("未知") ? "Unknown client" : label
    }

    private static func status(
        snapshot: PanelSnapshot?,
        errorMessage: String?,
        isStale: Bool,
        isRefreshing: Bool,
        now: Date
    ) -> MenuStatusPresentation {
        if isStale, let snapshot {
            let age = sampleDescription(snapshot.generatedAt, now: now)
            let detail = errorMessage.map { "Showing older data · \(age) · \($0)" } ?? "Showing older data · \(age)"
            return MenuStatusPresentation(text: "Showing older data · \(age)", accessibilityText: detail, isError: true)
        }
        if snapshot == nil, let errorMessage {
            return MenuStatusPresentation(text: "BitRouter unavailable", accessibilityText: "BitRouter unavailable. \(errorMessage)", isError: true)
        }
        if snapshot == nil {
            let text = isRefreshing ? "Loading today’s usage…" : "Waiting for usage data"
            return MenuStatusPresentation(text: text, accessibilityText: text, isError: false)
        }
        if let errorMessage {
            return MenuStatusPresentation(
                text: "Session loading failed",
                accessibilityText: "Session loading failed. \(errorMessage)",
                isError: true
            )
        }
        let age = sampleDescription(snapshot?.generatedAt, now: now)
        let text = isRefreshing ? "Refreshing · \(age)" : "Updated · \(age)"
        return MenuStatusPresentation(text: text, accessibilityText: text, isError: false)
    }

    private static func sampleDescription(_ sampledAt: Date?, now: Date) -> String {
        guard let sampledAt else { return "sample time unknown" }
        return "sampled \(relativeTime(sampledAt, now: now))"
    }

    private static func compactAge(_ sampledAt: Date?, now: Date) -> String {
        guard let sampledAt else { return "age unknown" }
        let relative = relativeTime(sampledAt, now: now)
        return relative.hasSuffix(" ago") ? String(relative.dropLast(4)) : relative
    }

    private static func relativeTime(_ date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        let magnitude = abs(seconds)
        let quantity: Int
        let unit: String
        if magnitude < 60 {
            quantity = magnitude
            unit = "s"
        } else if magnitude < 3_600 {
            quantity = magnitude / 60
            unit = "m"
        } else if magnitude < 86_400 {
            quantity = magnitude / 3_600
            unit = "h"
        } else {
            quantity = magnitude / 86_400
            unit = "d"
        }
        return seconds > 0 ? "in \(quantity)\(unit)" : "\(quantity)\(unit) ago"
    }

    private static func compactNumber(_ value: UInt64) -> String {
        let tiers: [(UInt64, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        guard let tier = tiers.first(where: { value >= $0.0 }) else { return String(value) }
        let scaled = Double(value) / Double(tier.0)
        let digits = scaled < 100 && value % tier.0 != 0 ? 1 : 0
        return scaled.formatted(
            .number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US"))
        ) + tier.1
    }
}
