import Foundation

public struct ReadTextFileInput: Codable, Equatable, Sendable {
    public static let defaultMaxBytes = 1_048_576

    public let path: String
    public let maxBytes: Int

    public init(path: String, maxBytes: Int = defaultMaxBytes) {
        self.path = path
        self.maxBytes = maxBytes
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case maxBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes)
            ?? Self.defaultMaxBytes
    }
}

public struct ReadTextFileOutput: Codable, Equatable, Sendable {
    public let path: String
    public let content: String
    public let byteCount: Int
    public let truncated: Bool

    public init(path: String, content: String, byteCount: Int, truncated: Bool) {
        self.path = path
        self.content = content
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public enum ReadTextFileError: Error, CustomStringConvertible, Sendable {
    case invalidLimit
    case notUTF8

    public var description: String {
        switch self {
        case .invalidLimit:
            return "maxBytes must be between 1 and 16 MiB."
        case .notUTF8:
            return "The requested file is not valid UTF-8 text."
        }
    }
}

public struct ReadTextFileTool: Tool {
    public static let descriptor = ToolDescriptor(
        name: "file.readText",
        version: "1",
        summary: "Read UTF-8 text from one explicitly authorized user file.",
        risk: .readOnly,
        capability: .readUserFile,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path of the explicitly selected file.")
                ]),
                "maxBytes": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(16_777_216),
                    "description": .string("Maximum bytes to read. Defaults to 1 MiB.")
                ])
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false)
        ])
    )

    public init() {}

    public func resource(for input: ReadTextFileInput) throws -> ResourceScope {
        .file(Self.canonicalURL(path: input.path).path)
    }

    public func execute(_ input: ReadTextFileInput) async throws -> ReadTextFileOutput {
        guard (1...16_777_216).contains(input.maxBytes) else {
            throw ReadTextFileError.invalidLimit
        }

        let url = Self.canonicalURL(path: input.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let requested = input.maxBytes + 1
        let raw = try handle.read(upToCount: requested) ?? Data()
        let truncated = raw.count > input.maxBytes
        let data = truncated ? Data(raw.prefix(input.maxBytes)) : raw

        guard let content = String(data: data, encoding: .utf8) else {
            throw ReadTextFileError.notUTF8
        }

        return ReadTextFileOutput(
            path: url.path,
            content: content,
            byteCount: data.count,
            truncated: truncated
        )
    }

    public func metadata(
        for input: ReadTextFileInput,
        output: ReadTextFileOutput
    ) -> [String: JSONValue] {
        [
            "encoding": .string("utf-8"),
            "bytesRead": .number(Double(output.byteCount)),
            "truncated": .bool(output.truncated)
        ]
    }

    private static func canonicalURL(path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
