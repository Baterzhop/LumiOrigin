#if canImport(SwiftUI)
import SwiftUI
import LumiCore

struct ConversationSidebarSection: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        Section("Conversations") {
            HStack {
                Button {
                    model.createConversation()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .disabled(!model.canChangeConversation)

                if !model.isSessionReady {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }

            if let active = model.activeConversation {
                TextField("Conversation title", text: $model.conversationTitleDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canChangeConversation)

                HStack {
                    Button("Rename") {
                        model.saveConversationTitle()
                    }
                    .disabled(
                        !model.canChangeConversation
                        || model.conversationTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.conversationTitleDraft == active.title
                    )

                    Spacer()
                    Text("\(model.messages.count) / \(active.messageCount) msg")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if model.hasOlderMessages || model.isLoadingOlderMessages {
                    Button {
                        model.loadOlderMessages()
                    } label: {
                        if model.isLoadingOlderMessages {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Loading earlier messages…")
                            }
                        } else {
                            Label("Load earlier messages", systemImage: "arrow.up.circle")
                        }
                    }
                    .disabled(model.isLoadingOlderMessages || model.isSending || model.isAgentRunning)
                }
            }

            if let error = model.conversationError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }

            if model.conversations.isEmpty {
                Text(model.isSessionReady ? "No conversations" : "Loading conversations…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.conversations.prefix(12)) { conversation in
                    HStack(spacing: 6) {
                        Button {
                            model.selectConversation(conversation)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if conversation.id == model.activeConversationID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                    }
                                    Text(conversation.title)
                                        .font(.caption.weight(conversation.id == model.activeConversationID ? .semibold : .regular))
                                        .lineLimit(1)
                                }
                                Text(conversation.updatedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canChangeConversation || conversation.id == model.activeConversationID)

                        Button(role: .destructive) {
                            model.deleteConversation(conversation)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canChangeConversation)
                        .help("Delete this conversation and its transcript")
                    }
                }

                if model.conversations.count > 12 {
                    Text("+ \(model.conversations.count - 12) older conversations")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
