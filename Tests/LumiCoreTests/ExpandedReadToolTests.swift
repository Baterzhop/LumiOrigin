import XCTest
@testable import LumiCore

final class ExpandedReadToolTests: XCTestCase {
    func testWorkspaceSearchIsBoundedSandboxedAndFindsUnicodeText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-workspace-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "Alpha needle value\nУкраїнський ТЕСТ рядок".write(
            to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
        )
        try "No match here".write(
            to: root.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
        )

        let sandbox = WorkspaceSandbox(rootURL: root, maximumReadBytes: 8_192)
        let tool = SearchWorkspaceTextTool(
            sandbox: sandbox,
            maximumFilesScanned: 10,
            maximumResults: 5,
            maximumExcerptCharacters: 120
        )
        let output = try await tool.execute(arguments: ["query": .string("тест")])

        guard case .object(let object) = output,
              case .array(let matches)? = object["matches"] else {
            return XCTFail("Expected structured search output.")
        }
        XCTAssertEqual(matches.count, 1)
        guard case .object(let first) = matches[0] else { return XCTFail("Expected match row.") }
        XCTAssertEqual(first["path"], .string("one.txt"))
        XCTAssertTrue(first["excerpt"]?.stringValue?.contains("ТЕСТ") == true)
        XCTAssertEqual(tool.definition.access, .readOnly)
        XCTAssertEqual(tool.definition.risk, .low)
    }

    func testWorkspaceFileInfoDoesNotEscapeSandbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumi-workspace-info-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let tool = WorkspaceFileInfoTool(sandbox: WorkspaceSandbox(rootURL: root))
        let output = try await tool.execute(arguments: ["path": .string("note.txt")])
        guard case .object(let object) = output else { return XCTFail("Expected object.") }
        XCTAssertEqual(object["path"], .string("note.txt"))
        XCTAssertEqual(object["isRegularFile"], .boolean(true))

        do {
            _ = try await tool.execute(arguments: ["path": .string("../outside.txt")])
            XCTFail("Traversal should fail.")
        } catch let error as ToolRuntimeError {
            guard case .sandboxViolation = error else { return XCTFail("Expected sandbox violation, got \(error).") }
        }
    }

    func testSafeWebPolicyRejectsUnsafeTargetsAndSupportsOptionalAllowlist() throws {
        let policy = SafeWebPolicy()
        XCTAssertThrowsError(try policy.validated("http://example.com"))
        XCTAssertThrowsError(try policy.validated("https://localhost/private"))
        XCTAssertThrowsError(try policy.validated("https://127.0.0.1/private"))
        XCTAssertThrowsError(try policy.validated("https://10.0.0.1/private"))
        XCTAssertThrowsError(try policy.validated("https://user:secret@example.com/private"))
        XCTAssertEqual(try policy.validated("https://example.com/path#fragment").absoluteString, "https://example.com/path")

        let allowlisted = SafeWebPolicy(allowedHosts: ["example.com"])
        XCTAssertNoThrow(try allowlisted.validated("https://docs.example.com/a"))
        XCTAssertThrowsError(try allowlisted.validated("https://example.org/a"))
    }

    func testWebFetchRequiresExactConfirmationAndReturnsUntrustedBoundedText() async throws {
        let tool = FetchWebTextTool(
            fetcher: StubWebFetcher(
                response: WebFetchResponse(
                    url: URL(string: "https://example.com/data")!,
                    statusCode: 200,
                    contentType: "text/plain; charset=utf-8",
                    data: Data(String(repeating: "x", count: 4_000).utf8)
                )
            ),
            policy: SafeWebPolicy(allowedHosts: ["example.com"]),
            maximumBytes: 8_192,
            maximumCharacters: 2_000
        )
        let runtime = ToolRuntime(registry: ToolRegistry(tools: [tool]))
        let call = ToolCall(
            toolName: "web.fetch_text",
            arguments: ["url": .string("https://example.com/data")],
            origin: .agent
        )

        let pending = await runtime.execute(call)
        XCTAssertEqual(pending.status, .confirmationRequired)

        let wrong = await runtime.execute(
            call,
            confirmation: ToolConfirmation(callID: UUID(), approved: true)
        )
        XCTAssertEqual(wrong.status, .denied)

        let approved = await runtime.execute(
            call,
            confirmation: ToolConfirmation(callID: call.id, approved: true)
        )
        XCTAssertEqual(approved.status, .success)
        XCTAssertEqual(approved.trust, .untrusted)
        guard case .object(let object)? = approved.output else { return XCTFail("Expected web object.") }
        XCTAssertEqual(object["textTruncated"], .boolean(true))
        XCTAssertEqual(object["text"]?.stringValue?.count, 2_000)
    }

    func testCalendarAndReminderToolsArePrivateReadOnlyAndBounded() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = StubPersonalDataProvider(
            events: [
                CalendarEventSnapshot(
                    id: "event-1",
                    title: "Project review",
                    start: now,
                    end: now.addingTimeInterval(3_600),
                    isAllDay: false,
                    calendarTitle: "Work"
                )
            ],
            reminders: [
                ReminderSnapshot(id: "reminder-1", title: "Ship Lumi", dueDate: now, completed: false, listTitle: "Lumi")
            ]
        )
        let calendar = CalendarListEventsTool(provider: provider)
        let reminders = ReminderListTool(provider: provider)

        XCTAssertEqual(calendar.definition.access, .readOnly)
        XCTAssertEqual(calendar.definition.risk, .medium)
        XCTAssertTrue(calendar.definition.requiresConfirmation)
        XCTAssertEqual(reminders.definition.access, .readOnly)
        XCTAssertTrue(reminders.definition.requiresConfirmation)

        let runtime = ToolRuntime(registry: ToolRegistry(tools: [calendar, reminders]))
        let calendarCall = ToolCall(
            toolName: "calendar.list_events",
            arguments: [
                "start": .string("2023-11-14T00:00:00Z"),
                "end": .string("2023-11-16T00:00:00Z"),
                "limit": .integer(5)
            ],
            origin: .agent
        )
        let pendingCalendar = await runtime.execute(calendarCall)
        XCTAssertEqual(pendingCalendar.status, .confirmationRequired)
        let approvedCalendar = await runtime.execute(
            calendarCall,
            confirmation: ToolConfirmation(callID: calendarCall.id, approved: true)
        )
        XCTAssertEqual(approvedCalendar.status, .success)

        let reminderCall = ToolCall(
            toolName: "reminders.list",
            arguments: ["limit": .integer(5)],
            origin: .agent
        )
        let approvedReminder = await runtime.execute(
            reminderCall,
            confirmation: ToolConfirmation(callID: reminderCall.id, approved: true)
        )
        XCTAssertEqual(approvedReminder.status, .success)
    }
}

private struct StubWebFetcher: WebFetching {
    let response: WebFetchResponse

    func fetch(_ url: URL, maximumBytes: Int) async throws -> WebFetchResponse {
        XCTAssertLessThanOrEqual(response.data.count, maximumBytes)
        return response
    }
}

private struct StubPersonalDataProvider: CalendarReading, ReminderReading {
    let eventsValue: [CalendarEventSnapshot]
    let remindersValue: [ReminderSnapshot]

    init(events: [CalendarEventSnapshot], reminders: [ReminderSnapshot]) {
        self.eventsValue = events
        self.remindersValue = reminders
    }

    func events(from start: Date, to end: Date, limit: Int) async throws -> [CalendarEventSnapshot] {
        Array(eventsValue.prefix(limit))
    }

    func reminders(includeCompleted: Bool, limit: Int) async throws -> [ReminderSnapshot] {
        Array(remindersValue.filter { includeCompleted || !$0.completed }.prefix(limit))
    }
}
