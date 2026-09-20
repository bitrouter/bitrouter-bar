import Foundation

actor SlowPanelClient: PanelClientFetching {
    let panel: PanelSnapshot

    init(panel: PanelSnapshot) { self.panel = panel }

    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int) async throws -> PanelSnapshot {
        try? await Task.sleep(for: .milliseconds(100))
        return panel
    }
}

actor RacingPanelClient: PanelClientFetching {
    private var calls = 0
    let panel: PanelSnapshot

    init(panel: PanelSnapshot) { self.panel = panel }

    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int) async throws -> PanelSnapshot {
        calls += 1
        let call = calls
        try? await Task.sleep(for: call == 1 ? .milliseconds(150) : .milliseconds(10))
        let changed = TokenCount(value: UInt64(call), state: .known, hasUnknown: false)
        let clients = panel.clients.map {
            ClientUsage(id: $0.id, label: $0.label, tokens: changed, lastActivityAt: $0.lastActivityAt, sessions: $0.sessions, accounts: $0.accounts)
        }
        return PanelSnapshot(schemaVersion: panel.schemaVersion, generatedAt: panel.generatedAt, usageUpdatedAt: panel.usageUpdatedAt, since: since, until: until, clients: clients, sessionPage: panel.sessionPage, warnings: panel.warnings)
    }
}

actor CancellableSlowClient: PanelClientFetching {
    private(set) var calls = 0
    private(set) var cancellations = 0
    let panel: PanelSnapshot

    init(panel: PanelSnapshot) { self.panel = panel }

    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int) async throws -> PanelSnapshot {
        calls += 1
        do {
            try await Task.sleep(for: .milliseconds(60))
            return panel
        } catch {
            cancellations += 1
            throw error
        }
    }
}

actor PagingClient: PanelClientFetching {
    let first: PanelSnapshot
    let second: PanelSnapshot

    init(first: PanelSnapshot, second: PanelSnapshot) {
        self.first = first
        self.second = second
    }

    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int) async throws -> PanelSnapshot {
        let page = sessionOffset == 0 ? first : second
        return PanelSnapshot(schemaVersion: page.schemaVersion, generatedAt: page.generatedAt,
            usageUpdatedAt: page.usageUpdatedAt, since: since, until: until,
            clients: page.clients, sessionPage: page.sessionPage, warnings: page.warnings)
    }
}

actor MidnightClient: PanelClientFetching {
    private var pageZeroCalls = 0
    let yesterday: PanelSnapshot
    let nextPage: PanelSnapshot
    let today: PanelSnapshot

    init(yesterday: PanelSnapshot, nextPage: PanelSnapshot, today: PanelSnapshot) {
        self.yesterday = yesterday
        self.nextPage = nextPage
        self.today = today
    }

    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int) async throws -> PanelSnapshot {
        if sessionOffset > 0 { return nextPage }
        pageZeroCalls += 1
        return pageZeroCalls == 1 ? yesterday : today
    }
}

enum ContractTestFailure: Error {
    case assertion(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ContractTestFailure.assertion(message) }
}

let fixture = """
{
  "schema_version":1,
  "generated_at":"2026-09-19T20:00:00.123Z",
  "usage_updated_at":"2026-09-19T19:59:00Z",
  "since":"2026-09-19T04:00:00Z",
  "until":"2026-09-20T04:00:00Z",
  "clients":[{
    "id":"opaque-client","label":"Codex",
    "tokens":{"value":160000,"state":"known","has_unknown":false},
    "last_activity_at":"2026-09-19T19:58:00Z",
    "sessions":[{"id":"opaque-session","short_id":"a81f","tokens":{"value":128000,"state":"known","has_unknown":false},"last_activity_at":"2026-09-19T19:58:00Z"}],
    "accounts":[{"id":"acct-a","label":"Account A","shared":true,"mapping_state":"known","quota":{"state":"available","sampled_at":"2026-09-19T19:57:00Z","error":null,"windows":[{"label":"5-hour","remaining_percent":42,"remaining_tokens":null,"remaining_requests":null,"remaining_currency":null,"currency":null,"resets_at":"2026-09-19T22:00:00Z","reset_kind":"fixed"}]}}]
  }],
  "session_page":{"offset":0,"limit":100,"has_more":true,"next_offset":100},
  "warnings":[]
}
"""

do {
    let panel = try PanelDecoding.decoder.decode(PanelSnapshot.self, from: Data(fixture.utf8))
    try expect(panel.schemaVersion == 1, "schema version")
    try expect(panel.clients.first?.tokens.value == 160_000, "client total")
    try expect(panel.clients.first?.accounts.first?.shared == true, "shared account")
    try expect(panel.clients.first?.accounts.first?.quota.windows.first?.remainingPercent == 42, "quota percent")
    try expect(panel.sessionPage?.nextOffset == 100, "next offset")
    let mixedTokens = TokenCount(value: 17, state: .estimated, hasUnknown: true)
    try expect(mixedTokens.displayText == "≈17+ · Some usage unknown", "estimated partial qualifier")

    var calendar = Calendar(identifier: .gregorian)
    guard let zone = TimeZone(identifier: "America/New_York"),
    let now = ISO8601DateFormatter().date(from: "2026-03-09T03:59:59Z") else {
        throw ContractTestFailure.assertion("test date setup")
    }
    calendar.timeZone = zone
    let interval = PanelStore.todayInterval(now: now, calendar: calendar)
    try expect(interval.duration == (23 * 60 * 60) - 1, "DST natural day")

    let secondJSON = fixture
        .replacingOccurrences(of: "\"offset\":0", with: "\"offset\":100")
        .replacingOccurrences(of: "\"next_offset\":100", with: "\"next_offset\":null")
        .replacingOccurrences(of: "\"has_more\":true", with: "\"has_more\":false")
    let second = try PanelDecoding.decoder.decode(PanelSnapshot.self, from: Data(secondJSON.utf8))
    let merged = PanelStore.merging(panel, second)
    try expect(merged.clients.first?.sessions.count == 1, "session deduplication")
    try expect(merged.clients.first?.tokens.value == 160_000, "server total retained")
    try expect(merged.sessionPage?.hasMore == false, "last page")

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bitrouter-bar-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let fakeBro = temporaryDirectory.appendingPathComponent("bro")
    let encodedFixture = Data(fixture.utf8).base64EncodedString()
    let script = "#!/bin/sh\nprintf '%s' '\(encodedFixture)' | /usr/bin/base64 -D\n"
    try Data(script.utf8).write(to: fakeBro)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBro.path)
    let client = BroPanelClient(locator: BroExecutableLocator(environment: ["BITROUTER_BAR_BRO_PATH": fakeBro.path]))
    let processPanel = try await client.fetch(since: panel.since, until: panel.until, sessionLimit: 100)
    try expect(processPanel.clients.first?.label == "Codex", "native process client")

    let incompatibleBro = temporaryDirectory.appendingPathComponent("incompatible-bro")
    let incompatibleFixture = fixture.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")
    let incompatibleEncoded = Data(incompatibleFixture.utf8).base64EncodedString()
    try Data("#!/bin/sh\nprintf '%s' '\(incompatibleEncoded)' | /usr/bin/base64 -D\n".utf8).write(to: incompatibleBro)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: incompatibleBro.path)
    let incompatibleClient = BroPanelClient(locator: BroExecutableLocator(environment: ["BITROUTER_BAR_BRO_PATH": incompatibleBro.path]))
    do {
        _ = try await incompatibleClient.fetch(since: panel.since, until: panel.until, sessionLimit: 100)
        throw ContractTestFailure.assertion("incompatible schema expected")
    } catch BroClientError.incompatibleSchema {}

    var malformedObject = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any]
    guard var malformedClients = malformedObject?["clients"] as? [[String: Any]],
          let firstClient = malformedClients.first else {
        throw ContractTestFailure.assertion("malformed fixture setup")
    }
    malformedClients.append(firstClient)
    malformedObject?["clients"] = malformedClients
    let malformedData = try JSONSerialization.data(withJSONObject: malformedObject as Any)
    let malformedBro = temporaryDirectory.appendingPathComponent("malformed-bro")
    let malformedEncoded = malformedData.base64EncodedString()
    try Data("#!/bin/sh\nprintf '%s' '\(malformedEncoded)' | /usr/bin/base64 -D\n".utf8).write(to: malformedBro)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: malformedBro.path)
    let malformedClient = BroPanelClient(locator: BroExecutableLocator(environment: ["BITROUTER_BAR_BRO_PATH": malformedBro.path]))
    do {
        _ = try await malformedClient.fetch(since: panel.since, until: panel.until, sessionLimit: 100)
        throw ContractTestFailure.assertion("duplicate client rejection expected")
    } catch BroClientError.invalidResponse {}

    let expiredBro = temporaryDirectory.appendingPathComponent("expired-bro")
    let expiredEnvelope = #"{"error":{"kind":"command_failed","message":"panel_snapshot_expired: reload page zero","context":[],"hint":null}}"#
    let expiredEncoded = Data(expiredEnvelope.utf8).base64EncodedString()
    let expiredScript = "#!/bin/sh\nprintf '%s' '\(expiredEncoded)' | /usr/bin/base64 -D\nexit 1\n"
    try Data(expiredScript.utf8).write(to: expiredBro)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: expiredBro.path)
    let expiredClient = BroPanelClient(locator: BroExecutableLocator(environment: ["BITROUTER_BAR_BRO_PATH": expiredBro.path]))
    do {
        _ = try await expiredClient.fetch(since: panel.since, until: panel.until, sessionLimit: 100, sessionOffset: 100)
        throw ContractTestFailure.assertion("expired snapshot error expected")
    } catch let BroClientError.commandFailed(_, message) {
        try expect(message == "The session page expired. Refresh to reload today’s data.", "expired page guidance")
    }

    let stubbornBro = temporaryDirectory.appendingPathComponent("stubborn-bro")
    let stubbornScript = "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n"
    try Data(stubbornScript.utf8).write(to: stubbornBro)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubbornBro.path)
    let timeoutClient = BroPanelClient(
        locator: BroExecutableLocator(environment: ["BITROUTER_BAR_BRO_PATH": stubbornBro.path]),
        timeout: .milliseconds(50)
    )
    let timeoutStarted = ContinuousClock.now
    do {
        _ = try await timeoutClient.fetch(since: panel.since, until: panel.until, sessionLimit: 100)
        throw ContractTestFailure.assertion("timeout expected")
    } catch BroClientError.timedOut {
        try expect(timeoutStarted.duration(to: .now) < .seconds(1), "bounded forced process termination")
    }

    let closedStore = PanelStore(client: SlowPanelClient(panel: panel))
    closedStore.panelDidOpen()
    try await Task.sleep(for: .milliseconds(10))
    closedStore.panelDidClose()
    try await Task.sleep(for: .milliseconds(150))
    try expect(closedStore.snapshot == nil, "closed panel discards late response")

    let racingStore = PanelStore(client: RacingPanelClient(panel: panel))
    racingStore.panelDidOpen()
    try await Task.sleep(for: .milliseconds(10))
    racingStore.refresh()
    try await Task.sleep(for: .milliseconds(200))
    try expect(racingStore.snapshot?.clients.first?.tokens.value == 2, "newer refresh wins race")
    racingStore.panelDidClose()

    let slowClient = CancellableSlowClient(panel: panel)
    let slowStore = PanelStore(client: slowClient, pollingInterval: .milliseconds(20))
    slowStore.panelDidOpen()
    try await Task.sleep(for: .milliseconds(75))
    try expect(slowStore.snapshot != nil, "slow automatic refresh completes")
    let slowCancellations = await slowClient.cancellations
    try expect(slowCancellations == 0, "poll does not cancel an in-flight refresh")
    slowStore.panelDidClose()

    let additionalSession = SessionUsage(
        id: "opaque-session-2",
        shortID: "b92e",
        tokens: TokenCount(value: 32_000, state: .known, hasUnknown: false),
        lastActivityAt: panel.generatedAt
    )
    let nextClients = panel.clients.map {
        ClientUsage(id: $0.id, label: $0.label, tokens: $0.tokens, lastActivityAt: $0.lastActivityAt, sessions: [additionalSession], accounts: $0.accounts)
    }
    let nextPage = PanelSnapshot(
        schemaVersion: panel.schemaVersion,
        generatedAt: panel.generatedAt,
        usageUpdatedAt: panel.usageUpdatedAt,
        since: panel.since,
        until: panel.until,
        clients: nextClients,
        sessionPage: SessionPage(offset: 100, limit: 100, hasMore: false, nextOffset: nil),
        warnings: []
    )
    let pagingStore = PanelStore(client: PagingClient(first: panel, second: nextPage), pollingInterval: .milliseconds(20))
    pagingStore.panelDidOpen()
    try await Task.sleep(for: .milliseconds(10))
    pagingStore.loadMore()
    try await Task.sleep(for: .milliseconds(75))
    try expect(pagingStore.snapshot?.clients.first?.sessions.count == 2, "automatic poll preserves appended pages")
    pagingStore.panelDidClose()

    let currentDay = PanelStore.todayInterval()
    guard let yesterdayStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: currentDay.start) else {
        throw ContractTestFailure.assertion("yesterday setup")
    }
    let yesterdayPanel = PanelSnapshot(
        schemaVersion: panel.schemaVersion,
        generatedAt: panel.generatedAt,
        usageUpdatedAt: panel.usageUpdatedAt,
        since: yesterdayStart,
        until: currentDay.start,
        clients: panel.clients,
        sessionPage: panel.sessionPage,
        warnings: []
    )
    let yesterdayNextPage = PanelSnapshot(
        schemaVersion: panel.schemaVersion,
        generatedAt: panel.generatedAt,
        usageUpdatedAt: panel.usageUpdatedAt,
        since: yesterdayStart,
        until: currentDay.start,
        clients: nextClients,
        sessionPage: SessionPage(offset: 100, limit: 100, hasMore: false, nextOffset: nil),
        warnings: []
    )
    let todayPanel = PanelSnapshot(
        schemaVersion: panel.schemaVersion,
        generatedAt: panel.generatedAt,
        usageUpdatedAt: panel.usageUpdatedAt,
        since: currentDay.start,
        until: currentDay.end,
        clients: panel.clients,
        sessionPage: panel.sessionPage,
        warnings: []
    )
    let midnightStore = PanelStore(
        client: MidnightClient(yesterday: yesterdayPanel, nextPage: yesterdayNextPage, today: todayPanel),
        pollingInterval: .seconds(3_600)
    )
    midnightStore.panelDidOpen()
    try await Task.sleep(for: .milliseconds(10))
    midnightStore.loadMore()
    try await Task.sleep(for: .milliseconds(10))
    try expect(midnightStore.snapshot?.clients.first?.sessions.count == 2, "midnight setup has paginated snapshot")
    midnightStore.refreshAutomatically(now: currentDay.start.addingTimeInterval(12 * 60 * 60))
    try await Task.sleep(for: .milliseconds(10))
    try expect(midnightStore.snapshot?.since == currentDay.start, "midnight tick replaces yesterday snapshot")
    try expect(midnightStore.snapshot?.clients.first?.sessions.count == 1, "midnight tick resets pagination")
    midnightStore.panelDidClose()
    // Native actions can arrive before OR after NSMenu's close callback.
    for closeBeforeCommand in [true, false] {
        let commandStore = PanelStore(client: SlowPanelClient(panel: panel), pollingInterval: .seconds(3_600))
        commandStore.panelDidOpen()
        if closeBeforeCommand { commandStore.panelDidClose() }
        commandStore.refreshFromMenuCommand()
        if !closeBeforeCommand { commandStore.panelDidClose() }
        try await Task.sleep(for: .milliseconds(160))
        try expect(commandStore.snapshot != nil, "native refresh survives menu dismissal in either callback order")
        try expect(!commandStore.isRefreshing, "native command completes while closed")
        commandStore.cancelAll()
    }
    let commandPages = PanelStore(client: PagingClient(first: panel, second: nextPage), pollingInterval: .milliseconds(15))
    commandPages.panelDidOpen()
    try await Task.sleep(for: .milliseconds(15))
    commandPages.panelDidClose()
    commandPages.loadMoreFromMenuCommand()
    try await Task.sleep(for: .milliseconds(20))
    try expect(commandPages.snapshot?.clients.first?.sessions.count == 2, "native load-more completes after dismissal")
    commandPages.panelDidOpen()
    try await Task.sleep(for: .milliseconds(60))
    try expect(commandPages.snapshot?.clients.first?.sessions.count == 2, "native load-more remains visible on next open")
    commandPages.cancelAll()

    try runMenuPresentationTests()
    try await runNativeMenuTests(panel: panel, nextPage: nextPage)
    print("Contract tests passed")
} catch {
    FileHandle.standardError.write(Data("Contract tests failed: \(error)\n".utf8))
    exit(1)
}
