import XCTest
@testable import LumiClientCore

final class ModelConfigurationTests: XCTestCase {
    override func tearDown() {
        LumiModelConfiguration.reset()
        super.tearDown()
    }

    func testAcceptsLoopbackModelServerAndModelNames() throws {
        let url = try LumiModelConfiguration.validatedServerURL("http://127.0.0.1:11434")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(try LumiModelConfiguration.validatedModelName("qwen3.5:9b"), "qwen3.5:9b")
        XCTAssertEqual(try LumiModelConfiguration.validatedModelName("registry.example/team/model:latest"), "registry.example/team/model:latest")
    }

    func testRejectsUnsafeRemoteModelServerAndCredentials() {
        XCTAssertThrowsError(try LumiModelConfiguration.validatedServerURL("http://models.example.com:11434"))
        XCTAssertThrowsError(try LumiModelConfiguration.validatedServerURL("https://user:secret@models.example.com"))
        XCTAssertThrowsError(try LumiModelConfiguration.validatedServerURL("https://models.example.com?token=secret"))
        XCTAssertThrowsError(try LumiModelConfiguration.validatedServerURL("https://models.example.com#fragment"))
    }

    func testRejectsInvalidModelName() {
        XCTAssertThrowsError(try LumiModelConfiguration.validatedModelName(""))
        XCTAssertThrowsError(try LumiModelConfiguration.validatedModelName("model with spaces"))
        XCTAssertThrowsError(try LumiModelConfiguration.validatedModelName("model\nname"))
    }

    func testSaveAndReadModelSettings() throws {
        LumiModelConfiguration.reset()
        let saved = try LumiModelConfiguration.save(
            serverURL: "https://models.example.com",
            chatModel: "chat-model:7b",
            embeddingModel: "embed-model:latest",
            denseRetrievalEnabled: false
        )
        XCTAssertEqual(saved, LumiModelConfiguration.current())
        XCTAssertEqual(saved.serverURL.absoluteString, "https://models.example.com")
        XCTAssertFalse(saved.denseRetrievalEnabled)
    }

    func testManagedCoreEnvironmentPreservesExplicitOverrides() {
        let settings = LumiManagedModelSettings(
            serverURL: URL(string: "http://127.0.0.1:11434")!,
            chatModel: "saved-chat",
            embeddingModel: "saved-embed",
            denseRetrievalEnabled: true
        )
        let environment = LumiModelConfiguration.managedCoreEnvironment(
            settings: settings,
            existingEnvironment: ["LUMI_OLLAMA_MODEL": "explicit-chat"]
        )

        XCTAssertNil(environment["LUMI_OLLAMA_MODEL"])
        XCTAssertEqual(environment["LUMI_OLLAMA_URL"], "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(environment["LUMI_OLLAMA_EMBED_URL"], "http://127.0.0.1:11434/api/embed")
        XCTAssertEqual(environment["LUMI_EMBEDDING_MODEL"], "saved-embed")
        XCTAssertEqual(environment["LUMI_RAG_DENSE"], "true")
    }
}
