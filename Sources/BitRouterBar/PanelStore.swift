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
    private let pageSize = 100
    private let pollingInterval: Duration

    init(client: any PanelClientFetching = BroPanelClient(), pollingInterval: Duration = .seconds(5)) {
        self.client = client
        self.pollingInterval = pollingInterval
    }

    func panelDidOpen() {
        isOpen = true
        automaticRefreshPaused = false
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
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        operationTask?.cancel()
        operationTask = nil
        isRefreshing = false
        isLoadingMore = false
    }

    func refresh() {
        automaticRefreshPaused = false
        beginRefresh()
    }

    private func refreshAutomatically() {
        guard !automaticRefreshPaused, !isRefreshing, !isLoadingMore else { return }
        beginRefresh()
    }

    private func beginRefresh() {
        guard isOpen else { return }
        generation &+= 1
        let requestGeneration = generation
        operationTask?.cancel()
        isRefreshing = true
        isLoadingMore = false
        let interval = Self.todayInterval()
        let limit = pageSize
        operationTask = Task { [weak self, client] in
            let result: Result<PanelSnapshot, Error>
            do {
                result = .success(try await client.fetch(since: interval.start, until: interval.end, sessionLimit: limit, sessionOffset: 0))
            } catch {
                result = .failure(error)
            }
            guard let self, isOpen, generation == requestGeneration else { return }
            isRefreshing = false
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

    func loadMore() {
        guard let current = snapshot,
              current.sessionPage?.hasMore == true,
              let offset = current.sessionPage?.nextOffset,
              !isLoadingMore,
              isOpen else { return }
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
            guard let self, isOpen, generation == requestGeneration else { return }
            isLoadingMore = false
            operationTask = nil
            switch result {
            case let .success(next):
                snapshot = Self.merging(current, next)
                errorMessage = nil
            case let .failure(error) where error is CancellationError:
                return
            case let .failure(error):
                automaticRefreshPaused = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "More sessions could not be loaded."
                isStale = true
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
