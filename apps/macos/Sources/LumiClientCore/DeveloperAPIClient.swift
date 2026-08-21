import Foundation

public extension LumiAPIClient {
    func developerStatus() async throws -> DeveloperStatusDTO {
        let (data, response) = try await URLSession.shared.data(for: makeRequest(developerEndpoint("status")))
        try validateResponse(response)
        return try JSONDecoder().decode(DeveloperStatusDTO.self, from: data)
    }

    func createDeveloperSession(goal: String) async throws -> DeveloperSessionDTO {
        try await sendDeveloperJSON(
            developerEndpoint("sessions"),
            body: DeveloperSessionCreateRequestDTO(goal: goal),
            response: DeveloperSessionDTO.self
        )
    }

    func developerSession(_ sessionID: String) async throws -> DeveloperSessionDTO {
        let (data, response) = try await URLSession.shared.data(for: makeRequest(developerEndpoint("sessions", sessionID)))
        try validateResponse(response)
        return try JSONDecoder().decode(DeveloperSessionDTO.self, from: data)
    }

    func approveDeveloperPlan(_ sessionID: String) async throws -> DeveloperSessionDTO {
        try await sendDeveloperJSON(
            developerEndpoint("sessions", sessionID, "approve-plan"),
            body: ExplicitApprovalRequestDTO(approvedByUser: true),
            response: DeveloperSessionDTO.self
        )
    }

    func revalidateDeveloperSession(_ sessionID: String) async throws -> DeveloperSessionDTO {
        try await sendDeveloperJSON(
            developerEndpoint("sessions", sessionID, "validate"),
            body: ExplicitApprovalRequestDTO(approvedByUser: true),
            response: DeveloperSessionDTO.self
        )
    }

    func denyDeveloperPlan(_ sessionID: String) async throws -> DeveloperSessionDTO {
        let request = makeRequest(developerEndpoint("sessions", sessionID, "deny-plan"), method: "POST")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(DeveloperSessionDTO.self, from: data)
    }

    func publishDeveloperSession(_ sessionID: String) async throws -> DeveloperSessionDTO {
        try await sendDeveloperJSON(
            developerEndpoint("sessions", sessionID, "publish"),
            body: ExplicitApprovalRequestDTO(approvedByUser: true),
            response: DeveloperSessionDTO.self
        )
    }

    private func developerEndpoint(_ components: String...) -> URL {
        let prefix = baseURL.appendingPathComponent("v1").appendingPathComponent("developer")
        return components.reduce(prefix) { partial, component in partial.appendingPathComponent(component) }
    }

    private func sendDeveloperJSON<Body: Encodable, Response: Decodable>(
        _ url: URL,
        body: Body,
        response: Response.Type
    ) async throws -> Response {
        var request = makeRequest(url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateResponse(urlResponse)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
