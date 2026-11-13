//
//  AskAssistant.swift
//  Powston
//
//  The "Ask" chat. Answers questions about the user's site with read-only tools
//  (AskTools.swift). Uses Apple's Private Cloud Compute model on iOS 27 and falls
//  back to the on-device model, one question at a time, when it can't.
//  Nothing is stored: a conversation ends when the sheet closes.
//

import Foundation
import Combine
import FoundationModels
import os

struct AskMessage: Identifiable, Equatable {
    enum Role { case user, assistant, notice }

    let id = UUID()
    let role: Role
    var text: String
}

@available(iOS 26.0, *)
@MainActor
final class AskAssistant: ObservableObject {

    private static let log = Logger(subsystem: "com.bollar.Powston", category: "Ask")

    enum Mode: Equatable {
        /// Private Cloud Compute: full conversation, 32K context
        case privateCloud
        /// On-device model: each question is answered on its own
        case limited
        /// Apple Intelligence is off or not supported on this device
        case unavailable
    }

    @Published private(set) var messages: [AskMessage] = []
    @Published private(set) var isResponding = false
    @Published private(set) var mode: Mode = .unavailable
    @Published private(set) var isNearingLimit = false
    @Published private(set) var isLimitReached = false

    /// Opens Apple's options for a higher limit (iCloud+), when Apple offers them
    private(set) var showLimitOptions: (() -> Void)?

    private let tools: [any Tool]
    private let limitedTools: [any Tool]
    private var cloudSession: LanguageModelSession?
    private var responseTask: Task<Void, Never>?

    static let starterQuestions = [
        "What will my battery do tonight?",
        "How did yesterday go?",
        "What's my bill so far this month?",
        "When is power cheapest today?"
    ]

    init(tools: [any Tool], limitedTools: [any Tool]) {
        self.tools = tools
        self.limitedTools = limitedTools
        refreshMode()
    }

    var hasCloudModel: Bool { mode == .privateCloud }

    // MARK: - Model choice

    func refreshMode() {
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            if model.isAvailable {
                updateQuota(model.quotaUsage)
                if !model.quotaUsage.isLimitReached {
                    mode = .privateCloud
                    return
                }
            }
        }
        mode = SystemLanguageModel.default.isAvailable ? .limited : .unavailable
    }

    @available(iOS 27.0, *)
    private func updateQuota(_ usage: PrivateCloudComputeLanguageModel.QuotaUsage) {
        switch usage.status {
        case .belowLimit(let info):
            isNearingLimit = info.isApproachingLimit
            isLimitReached = false
        case .limitReached:
            isNearingLimit = false
            isLimitReached = true
        @unknown default:
            break
        }
        if let suggestion = usage.limitIncreaseSuggestion {
            showLimitOptions = { suggestion.show() }
        } else {
            showLimitOptions = nil
        }
    }

    // MARK: - Asking

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding, mode != .unavailable else { return }

        messages.append(AskMessage(role: .user, text: trimmed))
        isResponding = true
        responseTask = Task {
            await answer(trimmed)
            isResponding = false
        }
    }

    func cancel() {
        responseTask?.cancel()
        responseTask = nil
        isResponding = false
    }

    private func answer(_ question: String) async {
        if mode == .privateCloud, #available(iOS 27.0, *) {
            do {
                try await stream(question, in: cloudSessionForConversation())
                return
            } catch let error as PrivateCloudComputeLanguageModel.Error {
                Self.log.error("PCC error: \(String(describing: error), privacy: .public)")
                switchToLimited(after: error)
            } catch where Self.kind(of: error) == .contextFull {
                // The conversation outgrew the context; start a fresh one and retry
                cloudSession = nil
                messages.append(AskMessage(role: .notice, text: String(localized: "This conversation got long, so I started a fresh one.")))
                do {
                    try await stream(question, in: cloudSessionForConversation())
                    return
                } catch {
                    show(error)
                    return
                }
            } catch where Self.kind(of: error) == .refused || error is CancellationError {
                show(error)
                return
            } catch {
                // Anything else: answer this question on the iPhone, and try
                // Private Cloud Compute again with a fresh session next time
                Self.log.error("PCC answer failed: \(String(describing: error), privacy: .public)")
                cloudSession = nil
                guard SystemLanguageModel.default.isAvailable else {
                    show(error)
                    return
                }
                var note = String(localized: "Private Cloud Compute couldn't answer that, so your iPhone is answering instead.") + Self.detail(error)
                if !hasRunCloudCheck {
                    hasRunCloudCheck = true
                    note += "\n" + (await cloudCheck())
                }
                messages.append(AskMessage(role: .notice, text: note))
            }
        }

        // Limited mode: each question gets its own on-device session
        do {
            let session = LanguageModelSession(model: SystemLanguageModel.default, tools: limitedTools, instructions: Self.instructions(limited: true))
            try await stream(question, in: session)
        } catch {
            Self.log.error("On-device answer failed: \(String(describing: error), privacy: .public)")
            show(error)
        }
    }

    /// The error's own words, for TestFlight testers to report. Empty for cancellation.
    /// The innermost error, e.g. "(Private Cloud Compute error 32031)", for testers to report.
    /// The full chain goes to the log. Empty for cancellation.
    private static func detail(_ error: Error) -> String {
        if error is CancellationError { return "" }
        return "\n(" + innermost(error) + ")"
    }

    private static func innermost(_ error: Error) -> String {
        var current = error as NSError
        while true {
            let info = current.userInfo
            if let next = info[NSUnderlyingErrorKey] as? NSError {
                current = next
            } else if let list = info[NSMultipleUnderlyingErrorsKey] as? [NSError], let next = list.first {
                current = next
            } else {
                break
            }
        }
        let domain = current.domain
            .replacingOccurrences(of: "PrivateCloudComputeError", with: "Private Cloud Compute error")
            .replacingOccurrences(of: "FoundationModels.", with: "")
        return "\(domain) \(current.code)"
    }

    /// Run once per sheet after a PCC failure: is PCC reachable at all, and does it
    /// fail only with our tools? Answers go in the notice so testers can report them.
    private var hasRunCloudCheck = false

    private func cloudCheck() async -> String {
        guard #available(iOS 27.0, *) else { return "" }
        func attempt(_ session: LanguageModelSession) async -> String {
            do {
                _ = try await session.respond(to: "Reply with the single word OK.")
                return String(localized: "worked")
            } catch {
                Self.log.error("PCC check failed: \(String(describing: error), privacy: .public)")
                return String(localized: "failed") + " (" + Self.innermost(error) + ")"
            }
        }
        let plain = await attempt(LanguageModelSession(model: PrivateCloudComputeLanguageModel()))
        var result = String(localized: "Check: a plain request") + " " + plain
        if plain == String(localized: "worked") {
            let withInstructions = await attempt(LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(), instructions: Self.instructions(limited: false)))
            result += "; " + String(localized: "with instructions but no tools") + " " + withInstructions
        }
        return result + "."
    }

    @available(iOS 27.0, *)
    private func cloudSessionForConversation() -> LanguageModelSession {
        if let cloudSession { return cloudSession }
        let session = LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            tools: tools,
            instructions: Self.instructions(limited: false)
        )
        cloudSession = session
        return session
    }

    @available(iOS 27.0, *)
    private func switchToLimited(after error: PrivateCloudComputeLanguageModel.Error) {
        let model = PrivateCloudComputeLanguageModel()
        updateQuota(model.quotaUsage)
        cloudSession = nil
        mode = SystemLanguageModel.default.isAvailable ? .limited : .unavailable

        let reason: String
        switch error {
        case .quotaLimitReached:
            isLimitReached = true
            reason = String(localized: "You've reached today's limit for Private Cloud Compute.")
        case .networkFailure:
            reason = String(localized: "Private Cloud Compute can't be reached right now.")
        default:
            reason = String(localized: "Private Cloud Compute isn't available right now.")
        }
        if mode == .limited {
            messages.append(AskMessage(role: .notice, text: reason + " " + String(localized: "Answering on your iPhone instead, one question at a time.")))
        } else {
            messages.append(AskMessage(role: .notice, text: reason))
        }
    }

    private func stream(_ question: String, in session: LanguageModelSession) async throws {
        let index = messages.count
        messages.append(AskMessage(role: .assistant, text: ""))
        do {
            for try await snapshot in session.streamResponse(to: question) {
                try Task.checkCancellation()
                messages[index].text = snapshot.content
            }
        } catch {
            // Drop the empty bubble so a retry or error notice takes its place
            if messages.indices.contains(index), messages[index].text.isEmpty {
                messages.remove(at: index)
            }
            throw error
        }
        #if DEBUG
        Self.log.info("Answer: \(self.messages[index].text, privacy: .public)")
        #endif
        if #available(iOS 27.0, *), mode == .privateCloud {
            updateQuota(PrivateCloudComputeLanguageModel().quotaUsage)
        }
    }

    private func show(_ error: Error) {
        if error is CancellationError { return }
        let text: String
        switch Self.kind(of: error) {
        case .refused:
            text = String(localized: "I can't help with that one. Try asking about your battery, prices or savings.")
        case .contextFull:
            text = String(localized: "That needs more data than I can look at on your iPhone. Try a shorter time span.")
        case .other:
            text = String(localized: "Something went wrong answering that. Please try again.") + Self.detail(error)
        }
        messages.append(AskMessage(role: .notice, text: text))
    }

    private enum ErrorKind { case contextFull, refused, other }

    private static func kind(of error: Error) -> ErrorKind {
        if #available(iOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextFull
            case .guardrailViolation, .refusal: return .refused
            default: return .other
            }
        }
        // iOS 26 reports the same failures as GenerationError
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextFull
            case .guardrailViolation, .refusal: return .refused
            default: return .other
            }
        }
        return .other
    }

    // MARK: - Instructions

    static func instructions(limited: Bool) -> String {
        let now = Date.now.formatted(date: .complete, time: .shortened)
        return """
        You answer questions about one household's home battery, solar and electricity prices. \
        The household's battery is run by Powston, a controller that buys power when it's cheap \
        and sells or uses it when it's expensive. It is now \(now).

        Use the tools to look up facts. Never guess a number: if a tool doesn't give it, say you don't have it. \
        Questions are about the site selected in the app unless the user names another site.

        Rules:
        - Inverter readings are not utility meter data. Never present them as billing evidence. \
        Call any bill or cost total an estimate, and say the retailer's bill is the real figure.
        - You can only look. You can't change settings, start a battery hold or override the controller. \
        If asked to, say the user can do it in the app.
        - The controller has no fixed plan. It decides every few minutes from prices and the battery, \
        so describe what it is likely to do and say it can change.
        - Peak periods are expensive to import. Negative prices mean being paid to use power.
        - Write prices in cents per kWh as the tools give them, like 15.7¢/kWh. Never put $ in front of a ¢ amount. \
        Write money in dollars, like $3.75. Use kWh for energy and kW for power.
        - The wholesale market price ($/MWh) isn't what the household pays. Mention it only if asked.
        - Use Australian English spelling.
        - Answer in a few short sentences or a short list. No tables.
        \(limited ? "- Keep answers brief; you are answering one question with a small model." : "")
        """
    }
}
