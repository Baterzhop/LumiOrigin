import XCTest
@testable import LumiClientCore

final class LumiClientCoreTests: XCTestCase {
    func testDecodesStartedEvent() throws {
        let data = Data(#"{"type":"started","generation_id":"g1","conversation_id":"c1"}"#.utf8)
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: data)
        XCTAssertEqual(event.type, .started)
        XCTAssertEqual(event.generationID, "g1")
        XCTAssertEqual(event.conversationID, "c1")
    }

    func testDecodesCompletedMetadata() throws {
        let data = Data(#"{"type":"completed","generation_id":"g1","conversation_id":"c1","content":"hello","message_id":"m1","provider":"ollama","model":"llama3.2","fallback":false,"finish_reason":"stop"}"#.utf8)
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: data)
        XCTAssertEqual(event.type, .completed)
        XCTAssertEqual(event.messageID, "m1")
        XCTAssertEqual(event.provider, "ollama")
        XCTAssertEqual(event.finishReason, "stop")
    }

    func testDecodesCitationMetadata() throws {
        let data = Data(#"{"type":"started","generation_id":"g1","conversation_id":"c1","citations":[{"chunk_id":"ch1","document_id":"d1","title":"Manual","source":"manual.pdf","text":"torque 20 Nm","score":0.2,"page":4,"section":"page-4","retrieval":["dense","fts5"]}]}"#.utf8)
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: data)
        XCTAssertEqual(event.citations?.first?.chunkID, "ch1")
        XCTAssertEqual(event.citations?.first?.page, 4)
        XCTAssertEqual(event.citations?.first?.retrieval, ["dense", "fts5"])
    }
}
