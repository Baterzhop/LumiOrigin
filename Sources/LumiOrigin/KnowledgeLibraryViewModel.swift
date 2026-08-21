#if canImport(SwiftUI)
import Foundation
import SwiftUI
import LumiCore

@MainActor
final class KnowledgeLibraryViewModel: ObservableObject {
    @Published var sources: [KnowledgeSourceRecord] = []
    @Published var isImporting = false
    @Published var status: String?
    @Published var error: String?

    private let library: any KnowledgeLibraryManaging
    private var importTask: Task<Void, Never>?

    init(library: any KnowledgeLibraryManaging = LumiEngine.persistentKnowledgeLibrary()) {
        self.library = library
        refresh()
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        importTask?.cancel()
        isImporting = true
        error = nil
        status = "Preparing \(urls.count) file\(urls.count == 1 ? "" : "s")…"

        importTask = Task {
            var imported = 0
            var sparseOnly = 0
            var failures: [String] = []

            for url in urls {
                if Task.isCancelled { break }
                do {
                    status = "Reading \(url.lastPathComponent)…"
                    let document = try await KnowledgeFileLoader.load(url: url)
                    status = "Indexing \(url.lastPathComponent)…"
                    let report = try await library.ingest(document)
                    imported += 1
                    if !report.denseIndexed {
                        sparseOnly += 1
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            await reloadSources()
            isImporting = false
            importTask = nil

            if Task.isCancelled {
                status = "Import cancelled"
                return
            }

            if imported > 0 {
                if sparseOnly > 0 {
                    status = "Imported \(imported). \(sparseOnly) indexed with sparse search only."
                } else {
                    status = "Imported \(imported) file\(imported == 1 ? "" : "s") with sparse + dense search."
                }
            } else {
                status = nil
            }

            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    func cancelImport() {
        importTask?.cancel()
        status = "Cancelling import…"
    }

    func remove(_ source: KnowledgeSourceRecord) {
        guard !isImporting else { return }
        error = nil
        Task {
            do {
                try await library.removeSource(id: source.id)
                await reloadSources()
                status = "Removed \(source.title)"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func refresh() {
        Task { await reloadSources() }
    }

    private func reloadSources() async {
        do {
            sources = try await library.listSources(limit: 100)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
