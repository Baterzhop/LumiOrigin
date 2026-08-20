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

    func testDecodesRecalledMemoryMetadata() throws {
        let data = Data(#"{"type":"started","generation_id":"g1","conversation_id":"c1","memories":[{"memory_id":"mem1","kind":"preference","title":"UI","content":"Prefer SwiftUI for the macOS client","source":"user","score":0.01,"retrieval":["fts5","dense"]}]}"#.utf8)
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: data)
        XCTAssertEqual(event.memories?.first?.memoryID, "mem1")
        XCTAssertEqual(event.memories?.first?.kind, "preference")
        XCTAssertEqual(event.memories?.first?.retrieval, ["fts5", "dense"])
    }

    func testDecodesMemoryRecord() throws {
        let data = Data(#"{"id":"mem1","kind":"fact","title":"Codename","content":"Aurora Zebra","source":"user","approved":true,"created_at":"2026-08-20 10:00:00","updated_at":"2026-08-20 10:01:00","metadata":{"approval":"explicit"}}"#.utf8)
        let memory = try JSONDecoder().decode(MemoryRecordDTO.self, from: data)
        XCTAssertEqual(memory.id, "mem1")
        XCTAssertTrue(memory.approved)
        XCTAssertEqual(memory.title, "Codename")
    }

    func testDecodesAwaitingApprovalTask() throws {
        let data = Data(#"{"id":"t1","conversation_id":null,"goal":"create file","status":"awaiting_approval","step_count":1,"max_steps":8,"max_tool_calls":6,"deadline_at":"2026-08-20T10:00:00+00:00","result_text":null,"error":null,"waiting_tool_call_id":"tc1","tool_calls":[{"id":"tc1","task_id":"t1","tool_name":"workspace.write_text","risk":"high","status":"awaiting_approval","decision_reason":"confirmation_required","error":null,"created_at":"2026-08-20 10:00:00"}]}"#.utf8)
        let task = try JSONDecoder().decode(AgentTaskDTO.self, from: data)
        XCTAssertEqual(task.status, "awaiting_approval")
        XCTAssertEqual(task.waitingToolCallID, "tc1")
        XCTAssertEqual(task.toolCalls.first?.toolName, "workspace.write_text")
        XCTAssertEqual(task.toolCalls.first?.risk, "high")
    }

    func testDecodesRuntimeToolAndMemoryStatus() throws {
        let data = Data(#"{"ok":true,"streaming":true,"provider":"ollama","model":"llama3.2","active_generations":0,"tools":{"count":5,"workspace":"/tmp/lumi","critical_enabled":false},"memory":{"count":3,"semantic_enabled":true,"embedding_model":"embeddinggemma","recall_k":4,"context_max_input_tokens":6000,"context_recent_tokens":3500}}"#.utf8)
        let runtime = try JSONDecoder().decode(RuntimeStatusResponse.self, from: data)
        XCTAssertEqual(runtime.tools?.count, 5)
        XCTAssertEqual(runtime.tools?.workspace, "/tmp/lumi")
        XCTAssertEqual(runtime.tools?.criticalEnabled, false)
        XCTAssertEqual(runtime.memory?.count, 3)
        XCTAssertEqual(runtime.memory?.semanticEnabled, true)
        XCTAssertEqual(runtime.memory?.contextRecentTokens, 3500)
    }
}
