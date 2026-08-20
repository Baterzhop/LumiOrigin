import SwiftUI

struct ContentView: View {
    @StateObject private var model = ChatViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            chat
        }
        .frame(minWidth: 980, minHeight: 680)
        .task {
            await model.refreshRuntime()
        }
    }

    private var sidebar: some View {
        List {
            Section("Runtime") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.status.contains("offline") || model.status.contains("error") ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    Text(model.status)
                }
                LabeledContent("Core", value: model.coreVersion)
                LabeledContent("Provider", value: model.providerName)
                LabeledContent("Model", value: model.modelName)
            }

            Section("Conversation") {
                Text(model.conversationID ?? "New conversation")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("New conversation", action: model.newConversation)
                    .disabled(model.isGenerating)
            }

            Section("M1") {
                Label("SSE streaming", systemImage: "waveform")
                Label("Cancel generation", systemImage: "stop.circle")
                Label("Durable messages", systemImage: "externaldrive")
            }
        }
        .navigationTitle("Lumi V4")
    }

    private var chat: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lumi")
                    .font(.headline)
                Text("Local-first AI runtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isGenerating {
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
                        VStack(spacing: 10) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text("Lumi is ready")
                                .font(.title3.weight(.semibold))
                            Text("Messages stream from Lumi Core in real time. Ollama is used when available; otherwise the core reports fallback mode.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 520)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 110)
                    }

                    ForEach(model.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: model.messages.last?.content) { _ in
                if let id = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Lumi…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit {
                    if !model.isGenerating {
                        model.send()
                    }
                }

            if model.isGenerating {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .help("Stop generation")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(14)
    }
}

private struct MessageBubbleView: View {
    let message: ChatBubble

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 100)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(message.role == .user ? "You" : "Lumi")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let model = message.model, message.role == .assistant {
                        Text(model)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                if message.content.isEmpty && message.role == .assistant {
                    Text("…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )

            if message.role == .assistant {
                Spacer(minLength: 100)
            }
        }
    }
}
