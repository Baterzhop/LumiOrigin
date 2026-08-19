import Foundation

public actor MemoryStore {
    private var messages: [ChatMessage] = []
    private let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = max(10, capacity)
    }

    @discardableResult
    public func append(role: ChatRole, content: String) -> ChatMessage {
        let message = ChatMessage(role: role, content: content)
        messages.append(message)
        trimIfNeeded()
        return message
    }

    public func recent(limit: Int = 16) -> [ChatMessage] {
        Array(messages.suffix(max(0, limit)))
    }

    public func all() -> [ChatMessage] {
        messages
    }

    public func clear() {
        messages.removeAll(keepingCapacity: true)
    }

    public var count: Int {
        messages.count
    }

    private func trimIfNeeded() {
        guard messages.count > capacity else { return }
        messages.removeFirst(messages.count - capacity)
    }
}
