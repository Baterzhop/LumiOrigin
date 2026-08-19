#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct ContentView: View {
    @StateObject private var model = ChatViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            chatPanel
        }
        .frame(minWidth: 980, minHeight: 680)
    }

    private var sidebar: some View {
        List {
            Section("Mode") {
                Picker("Profile", selection: $model.selectedProfile) {
                    ForEach(model.profiles, id: \.self) { profile in
                        Text(profile.capitalized).tag(profile)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Runtime") {
                Label(model.status, systemImage: "circle.fill")
                LabeledContent("Intent", value: model.lastIntent.rawValue)
                LabeledContent("Memory", value: "\(model.messages.count)")
            }

            Section("Context") {
                if model.contextHits.isEmpty {
                    Text("No retrieved context")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.contextHits.prefix(4), id: \.document.id) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.document.title)
                                .font(.subheadline.weight(.semibold))
                            Text(hit.score.formatted(.number.precision(.fractionLength(2))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive, action: model.clear) {
                    Label("Clear conversation", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Lumi V3")
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumi")
                    .font(.headline)
                Text("Explicit memory · retrieval · prompt profiles · local model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: model.messages.count) { _ in
                if let id = model.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Lumi is ready")
                .font(.title3.weight(.semibold))
            Text("Ollama is used when available. Without it, Lumi stays usable in fallback mode.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Lumi…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit(model.send)

            Button(action: model.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
        }
        .padding(14)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 90) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "You" : "Lumi")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.role != .user { Spacer(minLength: 90) }
        }
    }
}
#endif
