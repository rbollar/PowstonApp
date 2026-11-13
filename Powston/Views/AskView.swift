//
//  AskView.swift
//  Powston
//
//  The "Ask" sheet opened from the Dashboard toolbar.
//

import SwiftUI
import FoundationModels

@available(iOS 26.0, *)
struct AskView: View {
    @StateObject private var assistant: AskAssistant
    @State private var question = ""
    @FocusState private var isFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(api: PowstonAPI) {
        _assistant = StateObject(wrappedValue: AskAssistant(
            tools: AskTools.all(api: api),
            limitedTools: AskTools.limited(api: api)
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if assistant.mode == .unavailable {
                    unavailableView
                } else {
                    conversation
                    inputBar
                }
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        assistant.cancel()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    statusBanner

                    if assistant.messages.isEmpty {
                        starters
                    }

                    ForEach(assistant.messages) { message in
                        AskBubble(message: message)
                            .id(message.id)
                    }

                    if assistant.isResponding, assistant.messages.last?.role != .assistant {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: assistant.messages) {
                if let last = assistant.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if assistant.mode == .limited {
            AskNotice(
                systemImage: "iphone",
                text: String(localized: "Limited mode: answering on your iPhone, one question at a time."),
                actionTitle: assistant.isLimitReached && assistant.showLimitOptions != nil ? String(localized: "Show options") : nil,
                action: assistant.showLimitOptions
            )
        } else if assistant.isNearingLimit {
            AskNotice(
                systemImage: "gauge.with.dots.needle.67percent",
                text: String(localized: "You're nearing today's limit for Private Cloud Compute."),
                actionTitle: assistant.showLimitOptions != nil ? String(localized: "Show options") : nil,
                action: assistant.showLimitOptions
            )
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your battery, prices or savings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(AskAssistant.starterQuestions, id: \.self) { starter in
                Button {
                    assistant.ask(starter)
                } label: {
                    Text(starter)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your battery, prices or savings", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .submitLabel(.send)
                .onSubmit(send)

            if assistant.isResponding {
                Button {
                    assistant.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let text = question
        question = ""
        assistant.ask(text)
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            "Ask isn't available",
            systemImage: "apple.intelligence",
            description: Text("Ask needs Apple Intelligence. Turn it on in the Settings app, under Apple Intelligence & Siri.")
        )
    }
}

// MARK: - Pieces

private struct AskBubble: View {
    let message: AskMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        case .assistant:
            HStack {
                Text(LocalizedStringKey(message.text))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        case .notice:
            Label(message.text, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AskNotice: View {
    let systemImage: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.bold())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
