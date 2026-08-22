import Foundation

public struct CalendarEventSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarTitle: String?
    public let location: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        calendarTitle: String? = nil,
        location: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.location = location
    }
}

public struct ReminderSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let dueDate: Date?
    public let completed: Bool
    public let listTitle: String?

    public init(id: String, title: String, dueDate: Date?, completed: Bool, listTitle: String? = nil) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.completed = completed
        self.listTitle = listTitle
    }
}

public protocol CalendarReading: Sendable {
    func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventSnapshot]
}

public protocol ReminderReading: Sendable {
    func reminders(includeCompleted: Bool, limit: Int) async throws -> [ReminderSnapshot]
}

public struct CalendarListEventsTool: LumiTool, Sendable {
    public let provider: any CalendarReading

    public init(provider: any CalendarReading) {
        self.provider = provider
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "calendar.list_events",
            description: "Read calendar events in an explicit ISO-8601 time window. This accesses private local calendar data and therefore always requires confirmation.",
            inputSchema: [
                ToolFieldSchema(name: "start", type: .string, description: "ISO-8601 inclusive start timestamp."),
                ToolFieldSchema(name: "end", type: .string, description: "ISO-8601 exclusive end timestamp."),
                ToolFieldSchema(name: "limit", type: .integer, description: "Maximum events, 1 through 50.", required: false)
            ],
            outputDescription: "A bounded array of event metadata: id, title, start/end, all-day flag, calendar and optional location.",
            access: .readOnly,
            risk: .medium,
            requiresConfirmation: true,
            timeoutSeconds: 15
        )
    }

    public func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        guard let startText = arguments["start"]?.stringValue,
              let endText = arguments["end"]?.stringValue,
              let start = ToolDateCodec.parse(startText),
              let end = ToolDateCodec.parse(endText),
              start < end else {
            throw ToolRuntimeError.invalidArguments("`start` and `end` must be valid ISO-8601 timestamps with start < end.")
        }
        guard end.timeIntervalSince(start) <= 366 * 24 * 60 * 60 else {
            throw ToolRuntimeError.invalidArguments("Calendar windows are limited to 366 days.")
        }

        let limit = try boundedLimit(arguments["limit"], defaultValue: 20, maximum: 50)
        let events = try await provider.events(from: start, to: end, limit: limit)
        return .array(events.prefix(limit).map { event in
            var row: [String: ToolValue] = [
                "id": .string(event.id),
                "title": .string(String(event.title.prefix(500))),
                "start": .string(ToolDateCodec.string(event.start)),
                "end": .string(ToolDateCodec.string(event.end)),
                "isAllDay": .boolean(event.isAllDay)
            ]
            if let calendarTitle = event.calendarTitle { row["calendar"] = .string(String(calendarTitle.prefix(200))) }
            if let location = event.location { row["location"] = .string(String(location.prefix(500))) }
            return .object(row)
        })
    }
}

public struct ReminderListTool: LumiTool, Sendable {
    public let provider: any ReminderReading

    public init(provider: any ReminderReading) {
        self.provider = provider
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders.list",
            description: "Read a bounded list of local reminders. This accesses private reminder data and therefore always requires confirmation.",
            inputSchema: [
                ToolFieldSchema(name: "includeCompleted", type: .boolean, description: "Whether completed reminders should be returned.", required: false),
                ToolFieldSchema(name: "limit", type: .integer, description: "Maximum reminders, 1 through 50.", required: false)
            ],
            outputDescription: "A bounded array of reminder metadata: id, title, due date, completion state and list name.",
            access: .readOnly,
            risk: .medium,
            requiresConfirmation: true,
            timeoutSeconds: 15
        )
    }

    public func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        let includeCompleted: Bool
        if let value = arguments["includeCompleted"] {
            guard case .boolean(let flag) = value else {
                throw ToolRuntimeError.invalidArguments("`includeCompleted` must be boolean.")
            }
            includeCompleted = flag
        } else {
            includeCompleted = false
        }
        let limit = try boundedLimit(arguments["limit"], defaultValue: 20, maximum: 50)
        let reminders = try await provider.reminders(includeCompleted: includeCompleted, limit: limit)
        return .array(reminders.prefix(limit).map { reminder in
            var row: [String: ToolValue] = [
                "id": .string(reminder.id),
                "title": .string(String(reminder.title.prefix(500))),
                "completed": .boolean(reminder.completed)
            ]
            if let dueDate = reminder.dueDate { row["dueDate"] = .string(ToolDateCodec.string(dueDate)) }
            if let listTitle = reminder.listTitle { row["list"] = .string(String(listTitle.prefix(200))) }
            return .object(row)
        })
    }
}

private func boundedLimit(_ value: ToolValue?, defaultValue: Int, maximum: Int) throws -> Int {
    guard let value else { return defaultValue }
    guard case .integer(let limit) = value, (1...maximum).contains(limit) else {
        throw ToolRuntimeError.invalidArguments("`limit` must be between 1 and \(maximum).")
    }
    return limit
}

private enum ToolDateCodec {
    static func parse(_ text: String) -> Date? {
        if let date = fractional.date(from: text) { return date }
        return basic.date(from: text)
    }

    static func string(_ date: Date) -> String {
        fractional.string(from: date)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basic = ISO8601DateFormatter()
}

#if canImport(EventKit)
import EventKit

public actor EventKitPersonalDataProvider: CalendarReading, ReminderReading {
    private let store = EKEventStore()

    public init() {}

    public func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventSnapshot] {
        guard try await requestAccess(to: .event) else {
            throw ToolRuntimeError.permissionDenied("Calendar access was not granted by macOS.")
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(max(0, limit))
            .map { event in
                CalendarEventSnapshot(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: event.title ?? "(untitled event)",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar?.title,
                    location: event.location
                )
            }
    }

    public func reminders(includeCompleted: Bool, limit: Int) async throws -> [ReminderSnapshot] {
        guard try await requestAccess(to: .reminder) else {
            throw ToolRuntimeError.permissionDenied("Reminders access was not granted by macOS.")
        }
        let predicate = store.predicateForReminders(in: nil)
        let items: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        return items
            .filter { includeCompleted || !$0.isCompleted }
            .sorted { lhs, rhs in
                let left = Self.date(from: lhs.dueDateComponents) ?? .distantFuture
                let right = Self.date(from: rhs.dueDateComponents) ?? .distantFuture
                if left == right { return (lhs.title ?? "") < (rhs.title ?? "") }
                return left < right
            }
            .prefix(max(0, limit))
            .map { reminder in
                ReminderSnapshot(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "(untitled reminder)",
                    dueDate: Self.date(from: reminder.dueDateComponents),
                    completed: reminder.isCompleted,
                    listTitle: reminder.calendar?.title
                )
            }
    }

    private func requestAccess(to type: EKEntityType) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(to: type) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    private static func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        return components.calendar?.date(from: components) ?? Calendar.current.date(from: components)
    }
}
#endif
