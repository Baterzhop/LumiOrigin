import Foundation

public actor ReflectionJournal {
    private var events: [ReflectionEvent] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(10, capacity)
    }

    public func record(input: String, intent: LumiIntent, response: String) {
        let preview = String(response.prefix(240))
        events.append(ReflectionEvent(input: input, intent: intent, responsePreview: preview))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func recent(limit: Int = 20) -> [ReflectionEvent] {
        Array(events.suffix(max(0, limit)))
    }

    public func clear() {
        events.removeAll(keepingCapacity: true)
    }
}
