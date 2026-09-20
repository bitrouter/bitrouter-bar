import Foundation

private enum MenuPresentationTestFailure: Error {
    case assertion(String)
}

func runMenuPresentationTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MenuPresentationTestFailure.assertion(message) }
    }

    let now = Date(timeIntervalSince1970: 10_000)
    try check(MenuPresentation.token(TokenCount(value: 16_864, state: .known, hasUnknown: false)).text == "16.9K", "preserve useful precision for live sample")
    let mixed = MenuPresentation.token(TokenCount(value: 128_400, state: .estimated, hasUnknown: true))
    try check(mixed.text == "≈128K+", "compact token flags")
    try check(mixed.accessibilityText.contains("128,400"), "exact accessible token count")
    try check(mixed.accessibilityText.contains("estimated") && mixed.accessibilityText.contains("unknown"), "accessible token qualifiers")

    let percentWindow = QuotaWindow(
        label: "5-hour", remainingPercent: 42, remainingTokens: nil, remainingRequests: nil,
        remainingCurrency: nil, currency: nil, resetsAt: now.addingTimeInterval(7_200), resetKind: .fixed
    )
    let tokenWindow = QuotaWindow(
        label: "weekly", remainingPercent: nil, remainingTokens: 50_000, remainingRequests: nil,
        remainingCurrency: nil, currency: nil, resetsAt: nil, resetKind: .unknown
    )
    let singleAccount = AccountQuota(
        id: "primary", label: "Codex account1 primary", shared: false, mappingState: .known,
        quota: QuotaStatus(state: .available, sampledAt: now, error: nil, windows: [percentWindow, tokenWindow])
    )
    let client = ClientUsage(
        id: "codex", label: "Codex", tokens: TokenCount(value: 128_400, state: .known, hasUnknown: false),
        lastActivityAt: now, sessions: [], accounts: [singleAccount]
    )
    let snapshot = PanelSnapshot(
        schemaVersion: 1, generatedAt: now, usageUpdatedAt: now, since: now, until: now,
        clients: [client], sessionPage: nil, warnings: []
    )
    let available = MenuPresentation(
        snapshot: snapshot, errorMessage: nil, isStale: false, isRefreshing: false, isLoadingMore: false, now: now
    )
    let quota = available.clients[0].quotaRows
    try check(quota[0].scopeText == "5h quota", "single account label hidden and window shortened")
    try check(quota[0].valueText == "42% left", "percent remains compact")
    try check(quota[0].toolTip.contains("resets in 2h"), "reset detail is available outside compact text")
    try check(quota[0].fraction == 0.42, "percent provides thin bar fraction")
    try check(quota[1].scopeText == "Weekly quota", "weekly label shortened")
    try check(quota[1].valueText == "50K tokens left", "token quota is not converted to percent")
    try check(quota[1].fraction == nil, "token quota has no invented fraction")

    let unknownAccount = AccountQuota(
        id: nil, label: nil, shared: false, mappingState: .unknown,
        quota: QuotaStatus(state: .unknown, sampledAt: nil, error: nil, windows: [])
    )
    let sharedAccount = AccountQuota(
        id: "team", label: "Codex Team primary", shared: true, mappingState: .known,
        quota: QuotaStatus(state: .available, sampledAt: now, error: nil, windows: [percentWindow])
    )
    let distinguishedClient = ClientUsage(
        id: "multi", label: "Multi", tokens: TokenCount(value: nil, state: .unknown, hasUnknown: true),
        lastActivityAt: now, sessions: [], accounts: [unknownAccount, sharedAccount]
    )
    let distinguishedSnapshot = PanelSnapshot(
        schemaVersion: 1, generatedAt: now, usageUpdatedAt: now, since: now, until: now,
        clients: [distinguishedClient], sessionPage: nil, warnings: []
    )
    let distinguished = MenuPresentation(
        snapshot: distinguishedSnapshot, errorMessage: nil, isStale: false, isRefreshing: false, isLoadingMore: false, now: now
    )
    let scopes = distinguished.clients[0].quotaRows.compactMap(\.scopeText)
    try check(scopes.contains("Unknown account"), "unknown account remains explicit")
    try check(scopes.contains("Team · Shared quota · 5h quota"), "multiple shared account remains distinct")

    let staleAccount = AccountQuota(
        id: "stale", label: nil, shared: false, mappingState: .known,
        quota: QuotaStatus(state: .stale, sampledAt: now.addingTimeInterval(-300), error: nil, windows: [percentWindow])
    )
    let staleClient = ClientUsage(
        id: "stale-client", label: "Codex", tokens: TokenCount(value: 99, state: .known, hasUnknown: false),
        lastActivityAt: now, sessions: [], accounts: [staleAccount]
    )
    let staleSnapshot = PanelSnapshot(
        schemaVersion: 1, generatedAt: now.addingTimeInterval(-120), usageUpdatedAt: now, since: now, until: now,
        clients: [staleClient], sessionPage: nil, warnings: []
    )
    let stale = MenuPresentation(
        snapshot: staleSnapshot, errorMessage: "Connection refused", isStale: true,
        isRefreshing: false, isLoadingMore: false, now: now
    )
    try check(stale.clients[0].tokenText == "99", "disconnection preserves prior usage")
    try check(stale.status.text.contains("sampled 2m ago"), "global stale status includes age")
    try check(stale.clients[0].quotaRows[0].valueText.contains("stale (5m)"), "stale quota includes sample age")

    let realWindow = QuotaWindow(
        label: "Codex · Weekly · primary", remainingPercent: 86, remainingTokens: nil,
        remainingRequests: nil, remainingCurrency: nil, currency: nil,
        resetsAt: now.addingTimeInterval(60), resetKind: .unknown
    )
    let realAccount = AccountQuota(
        id: "real", label: "Codex · 账户 1", shared: false, mappingState: .known,
        quota: QuotaStatus(state: .available, sampledAt: now, error: nil, windows: [realWindow])
    )
    let realClient = ClientUsage(
        id: "real-client", label: "Codex", tokens: TokenCount(value: 1, state: .known, hasUnknown: false),
        lastActivityAt: now, sessions: [], accounts: [realAccount]
    )
    let realSnapshot = PanelSnapshot(
        schemaVersion: 1, generatedAt: now, usageUpdatedAt: now, since: now, until: now,
        clients: [realClient], sessionPage: nil, warnings: []
    )
    let real = MenuPresentation(
        snapshot: realSnapshot, errorMessage: nil, isStale: false,
        isRefreshing: false, isLoadingMore: false, now: now
    )
    try check(real.clients[0].quotaRows[0].scopeText == "Weekly quota", "real compound scope removes redundant provider and primary")
    try check(real.clients[0].quotaRows[0].valueText == "86% left", "real quota stays compact")
    let sparkWindow = QuotaWindow(
        label: "Codex · Spark · Weekly · primary", remainingPercent: 80, remainingTokens: nil,
        remainingRequests: nil, remainingCurrency: nil, currency: nil, resetsAt: nil, resetKind: .rolling
    )
    let sparkAccount = AccountQuota(
        id: "spark", label: nil, shared: false, mappingState: .known,
        quota: QuotaStatus(state: .available, sampledAt: now, error: nil, windows: [sparkWindow])
    )
    let sparkClient = ClientUsage(
        id: "spark-client", label: "Codex", tokens: TokenCount(value: 1, state: .known, hasUnknown: false),
        lastActivityAt: now, sessions: [], accounts: [sparkAccount]
    )
    let sparkSnapshot = PanelSnapshot(
        schemaVersion: 1, generatedAt: now, usageUpdatedAt: now, since: now, until: now,
        clients: [sparkClient], sessionPage: nil, warnings: []
    )
    let spark = MenuPresentation(
        snapshot: sparkSnapshot, errorMessage: nil, isStale: false,
        isRefreshing: false, isLoadingMore: false, now: now
    )
    try check(spark.clients[0].quotaRows[0].scopeText == "Spark · Weekly quota", "extra product scope is preserved")

    let localizedUnknownAccount = AccountQuota(
        id: nil, label: "Claude · 账户未知", shared: false, mappingState: .unknown,
        quota: QuotaStatus(state: .unknown, sampledAt: nil, error: nil, windows: [])
    )
    let localizedUnknownClient = ClientUsage(
        id: "unknown", label: "未知客户端", tokens: TokenCount(value: nil, state: .unknown, hasUnknown: true),
        lastActivityAt: now,
        sessions: [SessionUsage(id: "unknown-session", shortID: "未知", tokens: TokenCount(value: nil, state: .unknown, hasUnknown: true), lastActivityAt: nil)],
        accounts: [localizedUnknownAccount]
    )
    let localizedSnapshot = PanelSnapshot(
        schemaVersion: 1, generatedAt: now, usageUpdatedAt: now, since: now, until: now,
        clients: [localizedUnknownClient], sessionPage: nil, warnings: []
    )
    let localized = MenuPresentation(
        snapshot: localizedSnapshot, errorMessage: nil, isStale: false,
        isRefreshing: false, isLoadingMore: false, now: now
    )
    try check(localized.clients[0].title == "Unknown client", "unknown client label is English")
    try check(localized.clients[0].sessions[0].title == "Unknown session", "unknown session label is English")
    try check(localized.clients[0].quotaRows[0].scopeText == "Unknown account", "localized unknown account label is English")

    let pageFailure = MenuPresentation(
        snapshot: snapshot, errorMessage: "More sessions could not be loaded.", isStale: false,
        isRefreshing: false, isLoadingMore: false, now: now
    )
    try check(pageFailure.status.text == "Session loading failed", "page failure is not hidden")

    let unavailable = MenuPresentation(
        snapshot: nil, errorMessage: "Connection refused", isStale: false,
        isRefreshing: false, isLoadingMore: false, now: now
    )
    try check(unavailable.clients.isEmpty, "no snapshot does not invent usage")
    try check(unavailable.status.text == "BitRouter unavailable", "disconnected status is explicit")
}
