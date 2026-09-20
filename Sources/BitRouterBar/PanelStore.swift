import AppKit
import Foundation

@MainActor
final class PanelStore: ObservableObject {
    @Published private(set) var snapshot: PanelSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isStale = false

    private let client: any PanelClientFetching
    private var pollingTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var isOpen = false
    private var automaticRefreshPaused = false
    private var operationSurvivesClose = false
    private var preservePagesOnNextOpen = false
    private let pageSize = 100
    private let pollingInterval: Duration

    init(client: any PanelClientFetching = BroPanelClient(), pollingInterval: Duration = .seconds(5)) {
        self.client = client
        self.pollingInterval = pollingInterval
    }

    func panelDidOpen() {
        isOpen = true
        let sameDay = snapshot.map { $0.since == Self.todayInterval().start } ?? false
        automaticRefreshPaused = preservePagesOnNextOpen && sameDay
        preservePagesOnNextOpen = false
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            refreshAutomatically()
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollingInterval) } catch { return }
                refreshAutomatically()
            }
        }
    }

    func panelDidClose() {
        isOpen = false
        pollingTask?.cancel()
        pollingTask = nil
        guard !operationSurvivesClose else { return }
        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        isRefreshing = false
        isLoadingMore = false
    }

    func cancelAll() {
        operationSurvivesClose = false
        panelDidClose()
    }

    func refresh() {
        automaticRefreshPaused = false
        beginRefresh(interval: Self.todayInterval())
    }

    // Native menu commands dismiss the menu before their work completes.
    // Keep exactly this explicit read alive, without starting background polling.
    func refreshFromMenuCommand() {
        automaticRefreshPaused = false
        beginRefresh(interval: Self.todayInterval(), surviveClose: true)
    }

    func loadMoreFromMenuCommand() {
        loadMore(surviveClose: true)
    }

    func refreshAutomatically(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        let interval = Self.todayInterval(now: now, calendar: calendar)
        let crossedMidnight = snapshot.map { $0.since != interval.start } ?? false
        guard (!automaticRefreshPaused || crossedMidnight), !isRefreshing, !isLoadingMore else { return }
        if crossedMidnight { automaticRefreshPaused = false }
        beginRefresh(interval: interval)
    }

    private func beginRefresh(interval: DateInterval, surviveClose: Bool = false) {
        guard isOpen || surviveClose else { return }
        operationSurvivesClose = surviveClose
        preservePagesOnNextOpen = false
        generation &+= 1
        let requestGeneration = generation
        operationTask?.cancel()
        isRefreshing = true
        isLoadingMore = false
        let limit = pageSize
        operationTask = Task { [weak self, client] in
            let result: Result<PanelSnapshot, Error>
            do {
                result = .success(try await client.fetch(since: interval.start, until: interval.end, sessionLimit: limit, sessionOffset: 0))
            } catch {
                result = .failure(error)
            }
            guard let self, (isOpen || operationSurvivesClose), generation == requestGeneration else { return }
            isRefreshing = false
            operationSurvivesClose = false
            operationTask = nil
            switch result {
            case let .success(value):
                snapshot = value
                errorMessage = nil
                isStale = false
            case let .failure(error) where error is CancellationError:
                return
            case let .failure(error):
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "BitRouter could not load panel data."
                isStale = snapshot != nil
            }
        }
    }

    func loadMore(surviveClose: Bool = false) {
        guard let current = snapshot,
              current.sessionPage?.hasMore == true,
              let offset = current.sessionPage?.nextOffset,
              !isLoadingMore,
              (isOpen || surviveClose) else { return }
        operationSurvivesClose = surviveClose
        preservePagesOnNextOpen = surviveClose
        generation &+= 1
        let requestGeneration = generation
        operationTask?.cancel()
        isRefreshing = false
        isLoadingMore = true
        automaticRefreshPaused = true
        let limit = pageSize
        operationTask = Task { [weak self, client] in
            let result: Result<PanelSnapshot, Error>
            do {
                result = .success(try await client.fetch(
                    since: current.since,
                    until: current.until,
                    sessionLimit: limit,
                    sessionOffset: offset
                ))
            } catch {
                result = .failure(error)
            }
            guard let self, (isOpen || operationSurvivesClose), generation == requestGeneration else { return }
            isLoadingMore = false
            operationSurvivesClose = false
            operationTask = nil
            switch result {
            case let .success(next):
                snapshot = Self.merging(current, next)
                errorMessage = nil
            case let .failure(error) where error is CancellationError:
                return
            case let .failure(error):
                automaticRefreshPaused = false
                preservePagesOnNextOpen = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "More sessions could not be loaded."
            }
        }
    }

    static func todayInterval(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        guard let day = calendar.dateInterval(of: .day, for: now) else {
            return DateInterval(start: now, end: now.addingTimeInterval(0.001))
        }
        return DateInterval(start: day.start, end: max(now, day.start.addingTimeInterval(0.001)))
    }

    static func merging(_ current: PanelSnapshot, _ next: PanelSnapshot) -> PanelSnapshot {
        var nextByClient: [String: ClientUsage] = [:]
        for client in next.clients where nextByClient[client.id] == nil {
            nextByClient[client.id] = client
        }
        let clients = current.clients.map { client in
            guard let nextClient = nextByClient[client.id] else { return client }
            var seen = Set(client.sessions.map(\.id))
            let additional = nextClient.sessions.filter { seen.insert($0.id).inserted }
            return ClientUsage(
                id: client.id,
                label: nextClient.label,
                tokens: nextClient.tokens,
                lastActivityAt: nextClient.lastActivityAt,
                sessions: client.sessions + additional,
                accounts: nextClient.accounts
            )
        }
        return PanelSnapshot(
            schemaVersion: next.schemaVersion,
            generatedAt: next.generatedAt,
            usageUpdatedAt: next.usageUpdatedAt,
            since: current.since,
            until: current.until,
            clients: clients,
            sessionPage: next.sessionPage,
            warnings: next.warnings
        )
    }
}
