import Foundation

/// Observable operational events emitted by AgentRuntime.
/// These events expose runtime state and tool lifecycle only; they never contain hidden chain-of-thought.
public enum AgentEvent: Hashable, Sendable {
    case runUpdated(AgentRun)
    case toolStarted(runID: UUID, call: ToolCall)
    case toolFinished(runID: UUID, result: ToolResult)
    case confirmationRequired(runID: UUID, call: ToolCall)
    case terminal(AgentRun)

    public var runID: UUID {
        switch self {
        case .runUpdated(let run), .terminal(let run):
            return run.id
        case .toolStarted(let runID, _),
             .toolFinished(let runID, _),
             .confirmationRequired(let runID, _):
            return runID
        }
    }

    public var runSnapshot: AgentRun? {
        switch self {
        case .runUpdated(let run), .terminal(let run): return run
        case .toolStarted, .toolFinished, .confirmationRequired: return nil
        }
    }
}
