import Foundation

public struct WorkspaceFileInfoTool: LumiTool, Sendable {
    public let sandbox: WorkspaceSandbox

    public init(sandbox: WorkspaceSandbox) {
        self.sandbox = sandbox
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "workspace.file_info",
            description: "Read metadata for one file or directory inside the configured Lumi workspace.",
            inputSchema: [
                ToolFieldSchema(name: "path", type: .string, description: "Workspace-relative path.")
            ],
            outputDescription: "An object containing normalized relative path, name, type, size and modification timestamp when available.",
            access: .readOnly,
            risk: .low,
            timeoutSeconds: 5
        )
    }

    public func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        guard let path = arguments["path"]?.stringValue,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolRuntimeError.invalidArguments("`path` must be a non-empty string.")
        }

        let url = try sandbox.resolve(relativePath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        var object: [String: ToolValue] = [
            "path": .string(try sandbox.relativePath(for: url)),
            "name": .string(url.lastPathComponent),
            "isDirectory": .boolean(values.isDirectory ?? false),
            "isRegularFile": .boolean(values.isRegularFile ?? false)
        ]
        if let size = values.fileSize { object["sizeBytes"] = .integer(size) }
        if let modified = values.contentModificationDate {
            object["modifiedAt"] = .string(Self.iso8601.string(from: modified))
        }
        return .object(object)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct SearchWorkspaceTextTool: LumiTool, Sendable {
    public let sandbox: WorkspaceSandbox
    public let maximumFilesScanned: Int
    public let maximumResults: Int
    public let maximumExcerptCharacters: Int

    public init(
        sandbox: WorkspaceSandbox,
        maximumFilesScanned: Int = 250,
        maximumResults: Int = 40,
        maximumExcerptCharacters: Int = 320
    ) {
        self.sandbox = sandbox
        self.maximumFilesScanned = max(1, maximumFilesScanned)
        self.maximumResults = max(1, maximumResults)
        self.maximumExcerptCharacters = max(80, maximumExcerptCharacters)
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "workspace.search_text",
            description: "Search bounded UTF-8 text files inside the Lumi workspace. The search never leaves the workspace sandbox and skips binary/oversized files.",
            inputSchema: [
                ToolFieldSchema(name: "query", type: .string, description: "Case-insensitive text to find."),
                ToolFieldSchema(name: "path", type: .string, description: "Optional workspace-relative directory to search.", required: false),
                ToolFieldSchema(name: "limit", type: .integer, description: "Maximum results, 1 through 40.", required: false)
            ],
            outputDescription: "An object containing bounded match rows, files scanned and truncation metadata.",
            access: .readOnly,
            risk: .low,
            timeoutSeconds: 10
        )
    }

    public func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        guard let rawQuery = arguments["query"]?.stringValue else {
            throw ToolRuntimeError.invalidArguments("`query` must be a string.")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 256 else {
            throw ToolRuntimeError.invalidArguments("`query` must contain 1 through 256 characters.")
        }

        let requestedLimit: Int
        if let value = arguments["limit"] {
            guard case .integer(let integer) = value, (1...maximumResults).contains(integer) else {
                throw ToolRuntimeError.invalidArguments("`limit` must be between 1 and \(maximumResults).")
            }
            requestedLimit = integer
        } else {
            requestedLimit = min(20, maximumResults)
        }

        let basePath = arguments["path"]?.stringValue ?? ""
        let baseURL = try sandbox.resolve(relativePath: basePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolRuntimeError.executionFailed("Search path is not a directory.")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ToolRuntimeError.executionFailed("Could not enumerate the requested workspace directory.")
        }

        var scanned = 0
        var matches: [ToolValue] = []
        var scanTruncated = false
        var resultTruncated = false

        while let candidate = enumerator.nextObject() as? URL {
            if scanned >= maximumFilesScanned {
                scanTruncated = true
                break
            }

            guard let relative = try? sandbox.relativePath(for: candidate),
                  let safeURL = try? sandbox.resolve(relativePath: relative),
                  let values = try? safeURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            guard let size = values.fileSize, size <= sandbox.maximumReadBytes else { continue }
            scanned += 1

            guard let data = try? Data(contentsOf: safeURL, options: [.mappedIfSafe]),
                  data.count <= sandbox.maximumReadBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }

            let lower = text.lowercased()
            let needle = query.lowercased()
            var searchStart = lower.startIndex

            while searchStart < lower.endIndex,
                  let range = lower.range(of: needle, range: searchStart..<lower.endIndex) {
                let lowerOffset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let upperOffset = lower.distance(from: lower.startIndex, to: range.upperBound)
                let startOffset = max(0, lowerOffset - maximumExcerptCharacters / 2)
                let endOffset = min(text.count, upperOffset + maximumExcerptCharacters / 2)
                let start = text.index(text.startIndex, offsetBy: startOffset)
                let end = text.index(text.startIndex, offsetBy: endOffset)
                let excerpt = String(text[start..<end]).replacingOccurrences(of: "\u{0000}", with: "")

                matches.append(.object([
                    "path": .string(relative),
                    "excerpt": .string(String(excerpt.prefix(maximumExcerptCharacters))),
                    "characterOffset": .integer(lowerOffset)
                ]))

                if matches.count >= requestedLimit {
                    resultTruncated = true
                    break
                }
                searchStart = range.upperBound
            }

            if matches.count >= requestedLimit { break }
        }

        return .object([
            "query": .string(query),
            "matches": .array(matches),
            "filesScanned": .integer(scanned),
            "scanTruncated": .boolean(scanTruncated),
            "resultTruncated": .boolean(resultTruncated)
        ])
    }
}
