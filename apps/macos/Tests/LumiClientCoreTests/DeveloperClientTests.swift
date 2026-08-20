import Foundation
import XCTest
@testable import LumiClientCore

final class DeveloperClientTests: XCTestCase {
    func testDecodesDeveloperStatus() throws {
        let data = Data(#"{"enabled":true,"repository_ok":true,"repository_root":"/tmp/lumi-dev","base_branch":"main","current_branch":"main","clean":true,"publisher_configured":false,"error":null}"#.utf8)
        let status = try JSONDecoder().decode(DeveloperStatusDTO.self, from: data)
        XCTAssertTrue(status.enabled)
        XCTAssertTrue(status.repositoryOK)
        XCTAssertEqual(status.baseBranch, "main")
        XCTAssertEqual(status.currentBranch, "main")
        XCTAssertFalse(status.publisherConfigured)
    }

    func testDecodesDeveloperSessionProposalAndValidation() throws {
        let data = Data(#"{"id":"s1","goal":"change readme","status":"ready_to_publish","repository_root":"/tmp/repo","base_branch":"main","branch_name":"lumi/dev-demo","proposal":{"summary":"Change README","rationale":"Small change","changes":[{"path":"README.md","operation":"replace","content":"new","reason":"update"}]},"proposed_diff":"diff","checks":["python-core-tests"],"validation":[{"name":"python-core-tests","command":["python","-m","pytest"],"status":"passed","return_code":0,"output":"ok"}],"commit_sha":null,"pr_url":null,"error":null,"created_at":"2026-08-20 20:00:00","updated_at":"2026-08-20 20:01:00"}"#.utf8)
        let session = try JSONDecoder().decode(DeveloperSessionDTO.self, from: data)
        XCTAssertEqual(session.status, "ready_to_publish")
        XCTAssertEqual(session.proposal?.changes.first?.path, "README.md")
        XCTAssertEqual(session.validation.first?.status, "passed")
        XCTAssertEqual(session.branchName, "lumi/dev-demo")
    }
}
