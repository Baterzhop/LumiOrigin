import Foundation

/// Compatibility adapter for profile selection and legacy callers.
/// Runtime behavior is driven by `RequestClassification`, not by this enum alone.
public struct IntentRouter: Sendable {
    public init() {}

    public func detect(_ input: String) -> LumiIntent {
        let classification = HeuristicRequestClassifier().classify(LumiRequest(input: input))
        return intent(for: classification)
    }

    public func intent(for classification: RequestClassification) -> LumiIntent {
        if classification.capabilities.contains(.tools) || classification.mode == .agent {
            return .tool
        }
        if classification.capabilities.contains(.coding) {
            return .coding
        }
        if classification.capabilities.contains(.reflection) {
            return .reflection
        }
        if classification.capabilities.contains(.retrieval) || classification.capabilities.contains(.files) {
            return .knowledge
        }
        return .chat
    }
}
