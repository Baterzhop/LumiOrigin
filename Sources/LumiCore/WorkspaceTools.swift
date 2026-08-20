import Foundation

public struct WorkspaceSandbox: Sendable {
    public let rootURL: URL
    public let maximumReadBytes: Int

    public init(rootURL: URL, maximumReadBytes: Int = 262_144) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumReadBytes = max(1_024, maximumReadBytes)
    }

    public func resolve(relativePath: String, mustExist: Bool = true) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let component = trimmed.isEmpty ? "." : trimmed

        guard !component.hasPrefix("/") else {
            throw ToolRuntimeError.sandboxViolation("Absolute paths are not allowed.")
        }

        let candidate = rootURL
            .appendingPathComponent(component)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard contains(candidate) else {
            throw ToolRuntimeError.sandboxViolation("Path escapes the configured workspace root.")
        }

        if mustExist, !FileManager.default.fileExists(atPath: candidate.path) {
            throw ToolRuntimeError.executionFailed("Path does not exist: \(component)")
        }

        return candidate
    }

    private func contains(_ candidate: URL) -> Bool {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return candidate.path == rootURL.path || candidate.path.hasPrefix(rootPath)
    }
}

public struct ListWorkspaceFilesTool: LumiTool, Sendable {
    public let sandbox: WorkspaceSandbox

    public init(sandbox: WorkspaceSandbox) {
        self.sandbox = sandbox
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "workspace.list_files",
            description: "List direct children of a directory inside the configured Lumi workspace.",
            inputSchema: [
                ToolFieldSchema(
                    name: "path",
                    type: .string,
                    description: "Workspace-relative directory path. Use an empty string for the workspace root.",
                    required: false
                )
            ],
            outputDescription: "An array of objects containing relative path, name, directory flag and byte size when known.",
            access: .readOnly,
            risk: .low,
            timeoutSeconds: 5
        )
    }

    public func execute(arguments: [String: ToolValue]) async throws -> ToolValue {
        let relativePath = arguments["path"]?.stringValue ?? ""
        let directory = try sandbox.resolve(relativePath: relativePath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolRuntimeError.executionFailed("Requested path is not a directory.")
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let rows: [ToolValue] = try children.map { child in
            let safeChild = try sandbox.resolve(relativePath: relativePathFromRoot(child))
            let values = try safeChild.resourceValues(forKeys: keys)
            var object: [String: ToolValue] = [
                "name": .string(safeChild.lastPathComponent),
                "path": .string(relativePathFromRoot(safeChild)),
                "isDirectory": .boolean(values.isDirectory ?? false)
            ]
            if let size = values.fileSize {
                object["sizeBytes"] = .integer(size)
            }
            return .object(object)
        }

        return .array(rows)
    }

    private func relativePathFromRoot(_ url: URL) -> String {
        let root = sandbox.rootURL.path.hasSuffix("/") ? sandbox.rootURL.path : sandbox.rootURL.path + "/"
        if url.path == sandbox.rootURL.path { return "" }
        return String(url.path.dropFirst(root.count))
    }
}

public struct ReadWorkspaceTextFileTool: LumiTool, Sendable {
    public let sandbox: WorkspaceSandbox

    public init(sandbox: WorkspaceSandbox) {
        self.sandbox = sandbox
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "workspace.read_text_file",
            description: "Read a UTF-8 text file inside the configured Lumi workspace. Binary files and oversized files are rejected.",
            inputSchema: [
                ToolFieldSchema(
                    name: "path",
                    type: .string,
                    description: "Workspace-relative file path.",
                    required: true
                )
            ],
            outputDescription: "An object containing path, UTF-8 content and byte count.",
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

        let fileURL = try sandbox.resolve(relativePath: path)
        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isDirectory != true else {
            throw ToolRuntimeError.executionFailed("Requested path is not a regular file.")
        }

        if let size = values.fileSize, size > sandbox.maximumReadBytes {
            throw ToolRuntimeError.sandboxViolation(
                "File exceeds the read limit of \(sandbox.maximumReadBytes) bytes."
            )
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= sandbox.maximumReadBytes else {
            throw ToolRuntimeError.sandboxViolation(
                "File exceeds the read limit of \(sandbox.maximumReadBytes) bytes."
            )
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw ToolRuntimeError.executionFailed("File is not valid UTF-8 text.")
        }

        return .object([
            "path": .string(path),
            "content": .string(content),
            "sizeBytes": .integer(data.count)
        ])
    }
}
