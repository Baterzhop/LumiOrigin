#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore

@MainActor
final class RuntimeDiagnosticsViewModel: ObservableObject {
    @Published var report: LocalRuntimeDiagnosticReport?
    @Published var isChecking = false

    private let service: LocalRuntimeDiagnosticService
    private var task: Task<Void, Never>?

    init(service: LocalRuntimeDiagnosticService = .environment()) {
        self.service = service
        refresh()
    }

    func refresh() {
        task?.cancel()
        isChecking = true
        task = Task {
            let report = await service.check()
            guard !Task.isCancelled else { return }
            self.report = report
            self.isChecking = false
            self.task = nil
        }
    }
}
#endif
