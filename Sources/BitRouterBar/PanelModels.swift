import Foundation

struct PanelSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let usageUpdatedAt: Date
    let since: Date
    let until: Date
    let clients: [ClientUsage]
    let sessionPage: SessionPage?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case usageUpdatedAt = "usage_updated_at"
        case since, until, clients
        case sessionPage = "session_page"
        case warnings
    }
}

struct ClientUsage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let tokens: TokenCount
    let lastActivityAt: Date
    let sessions: [SessionUsage]
    let accounts: [AccountQuota]

    enum CodingKeys: String, CodingKey {
        case id, label, tokens, sessions, accounts
        case lastActivityAt = "last_activity_at"
    }
}

struct TokenCount: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case known, estimated, unknown }
    let value: UInt64?
    let state: State
    let hasUnknown: Bool

    enum CodingKeys: String, CodingKey {
        case value, state
        case hasUnknown = "has_unknown"
    }
}

extension TokenCount {
    var displayText: String {
        guard let value else { return "Unknown" }
        let formatted = value.formatted()
        var result = state == .estimated ? "≈\(formatted)" : formatted
        if hasUnknown { result += "+ · Some usage unknown" }
        return result
    }
}

struct SessionUsage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let shortID: String
    let tokens: TokenCount
    let lastActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, tokens
        case shortID = "short_id"
        case lastActivityAt = "last_activity_at"
    }
}

struct AccountQuota: Codable, Equatable, Identifiable, Sendable {
    enum MappingState: String, Codable, Sendable { case known, unknown }
    let id: String?
    let label: String?
    let shared: Bool
    let mappingState: MappingState
    let quota: QuotaStatus

    var stableID: String { id ?? "unknown-\(label ?? "account")" }

    enum CodingKeys: String, CodingKey {
        case id, label, shared, quota
        case mappingState = "mapping_state"
    }
}

struct QuotaStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case available, unsupported, unknown, error, stale }
    let state: State
    let sampledAt: Date?
    let error: String?
    let windows: [QuotaWindow]

    enum CodingKeys: String, CodingKey {
        case state, error, windows
        case sampledAt = "sampled_at"
    }
}

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    enum ResetKind: String, Codable, Sendable { case fixed, rolling, unknown }
    let label: String
    let remainingPercent: Double?
    let remainingTokens: UInt64?
    let remainingRequests: UInt64?
    let remainingCurrency: Double?
    let currency: String?
    let resetsAt: Date?
    let resetKind: ResetKind?

    var id: String { "\(label)-\(resetsAt?.timeIntervalSince1970 ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case label
        case remainingPercent = "remaining_percent"
        case remainingTokens = "remaining_tokens"
        case remainingRequests = "remaining_requests"
        case remainingCurrency = "remaining_currency"
        case currency
        case resetsAt = "resets_at"
        case resetKind = "reset_kind"
    }
}

struct SessionPage: Codable, Equatable, Sendable {
    let offset: Int
    let limit: Int
    let hasMore: Bool
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case offset, limit
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}

struct CommandErrorEnvelope: Codable, Sendable {
    let error: CommandErrorPayload
}

struct CommandErrorPayload: Codable, Sendable {
    let kind: String
    let message: String
    let context: [String]?
    let hint: String?
}

enum PanelDecoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let regular = ISO8601DateFormatter()
            guard let date = fractional.date(from: value) ?? regular.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC 3339 timestamp")
            }
            return date
        }
        return decoder
    }()
}
