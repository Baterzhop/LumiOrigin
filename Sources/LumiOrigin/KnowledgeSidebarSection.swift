#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import LumiCore

struct KnowledgeSidebarSection: View {
    @StateObject private var model = KnowledgeLibraryViewModel()
    @State private var isImporterPresented = false

    var body: some View {
        Section("Knowledge Library") {
            HStack {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Import files", systemImage: "doc.badge.plus")
                }
                .disabled(model.isImporting)

                if model.isImporting {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancelImport() }
                        .buttonStyle(.borderless)
                }
            }

            Text("Local TXT, Markdown and text-layer PDF files. Imported content is treated as untrusted evidence.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }

            if model.sources.isEmpty {
                Text("No imported sources")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sources.prefix(8)) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: icon(for: source.sourceType))
                                .foregroundStyle(.secondary)
                            Text(source.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                model.remove(source)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isImporting)
                            .help("Remove source from sparse and dense indexes")
                        }

                        HStack(spacing: 6) {
                            Text(source.sourceType.rawValue)
                            Text("·")
                            Text(source.updatedAt, style: .date)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        if let sourceURI = source.sourceURI {
                            Text(sourceURI)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }

                if model.sources.count > 8 {
                    Text("+ \(model.sources.count - 8) more sources")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.plainText, .markdown, .pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importFiles(urls)
            case .failure(let error):
                model.error = error.localizedDescription
            }
        }
    }

    private func icon(for type: KnowledgeSourceType) -> String {
        switch type {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.text"
        case .plainText: return "doc.plaintext"
        case .unknown: return "doc"
        }
    }
}
#endif
